/*
  ============================================================
                       MEC-AI
       Real-Time Wearable Health & Environment Monitor
  ============================================================

  Hardware:
  - ESP32-S3
  - MAX30102 (heart rate / SpO2)
  - SHT30x (temperature only)
  - ST7789 1.14" TFT
  - 3 Buttons (GPIO16, 15, 14 - RTC capable, used for sleep wake)
  - NeoPixel

  Buttons:
  - Button 1: cycle display mode (Health <-> Environment)
  - Button 2: short press = toggle Celsius/Fahrenheit
              long press  = cycle brightness (low/med/high)
  - Button 3: SOS toggle ONLY (short press flips sosActive).
              No long-press behavior on this button on purpose -
              an emergency control should never have a second,
              easily-confused meaning.

  SOS is a plain boolean (sosActive) so it's simple to hook into
  future integration - BLE alert, buzzer, LoRa, SMS module, etc.
  See handleSOSState() for the placeholder hook.
*/

#include <Wire.h>
#include <SPI.h>

#include <Adafruit_GFX.h>
#include <Adafruit_ST7789.h>
#include <Adafruit_NeoPixel.h>

#include "MAX30105.h"
#include "heartRate.h"
#include "spo2_algorithm.h"

#include <Adafruit_SHT31.h>

#include <esp_sleep.h>
#include <driver/rtc_io.h>

#include <BLEDevice.h>
#include <BLEServer.h>
#include <BLEUtils.h>
#include <BLE2902.h>

// ============================================================
// DISPLAY
// ============================================================
#define TFT_I2C_POWER 21
#define TFT_CS        7
#define TFT_DC        39
#define TFT_RST       40
#define TFT_BACKLITE  45
#define TFT_MOSI      35
#define TFT_SCLK      36

SPIClass spi = SPIClass(FSPI);
Adafruit_ST7789 tft(&spi, TFT_CS, TFT_DC, TFT_RST);


// ============================================================
// NEOPIXEL
// ============================================================
#define NEOPIXEL_PIN   33
#define NEOPIXEL_POWER 34
Adafruit_NeoPixel pixel(1, NEOPIXEL_PIN, NEO_GRB + NEO_KHZ800);

uint8_t pixelBrightnessLevels[3] = {10, 35, 80};  // low / med / high
int brightnessIndex = 1;                          // start at medium


// ============================================================
// I2C
// ============================================================
#define I2C_SDA 42
#define I2C_SCL 41


// ============================================================
// SENSORS
// ============================================================
MAX30105 maxSensor;
bool maxSensorFound = false;
Adafruit_SHT31 sht31 = Adafruit_SHT31();
bool sht31Found = false;


// ============================================================
// BUTTONS
// ============================================================
#define BUTTON1_PIN 16
#define BUTTON2_PIN 15
#define BUTTON3_PIN 8


// ============================================================
// DISPLAY MODE
// ============================================================
enum DisplayMode { HEALTH_MODE, ENV_MODE, MODE_COUNT };
DisplayMode displayMode = HEALTH_MODE;

bool useFahrenheit = false;


// ============================================================
// TIMERS
// ============================================================
unsigned long lastDisplayUpdate = 0;
unsigned long lastEnvUpdate     = 0;
unsigned long lastSpO2Update    = 0;

const unsigned long DISPLAY_INTERVAL = 100;  // 10 FPS
const unsigned long ENV_INTERVAL     = 1000; // SHT30x doesn't need fast polling
const unsigned long SPO2_INTERVAL    = 500;  // 2 Hz
bool displayDirty = true;


// ============================================================
// BUTTON DEBOUNCE + LONG PRESS
// ============================================================
bool lastRawState[3]   = {HIGH, HIGH, HIGH};
bool debouncedState[3] = {HIGH, HIGH, HIGH};
unsigned long lastDebounce[3] = {0, 0, 0};
const unsigned long debounceDelay = 30;

unsigned long pressStartTime[3] = {0, 0, 0};
bool longPressFired[3] = {false, false, false};
const unsigned long LONG_PRESS_MS = 700;


// ============================================================
// MAX30102 WEAR DETECTION
// ============================================================
#define IR_WEAR_THRESHOLD 50000
bool wearing = false;
unsigned long wearStartTime = 0;
unsigned long removalStartTime = 0;
const unsigned long WEAR_CONFIRM_TIME = 400;
const unsigned long REMOVE_CONFIRM_TIME = 600;


// ============================================================
// HEART RATE
// ============================================================
int currentHeartRate = 0;
int filteredHeartRate = 0;
bool heartRateValid = false;

#define HR_HISTORY_SIZE 5
int hrHistory[HR_HISTORY_SIZE];
int hrHistoryIndex = 0;
int hrHistoryCount = 0;

long lastBeatTime = 0;

// Heartbeat NeoPixel pulse (suppressed while SOS is active - SOS owns the LED then)
bool heartbeatFlashActive = false;
unsigned long heartbeatFlashUntil = 0;
const unsigned long HEARTBEAT_FLASH_MS = 90;


// ============================================================
// SPO2
// ============================================================
#define SPO2_BUFFER_SIZE 100
uint32_t irBuffer[SPO2_BUFFER_SIZE];
uint32_t redBuffer[SPO2_BUFFER_SIZE];
int spo2SampleCount = 0;

int32_t currentSpO2 = 0;
int32_t calculatedSpO2 = 0;
int8_t validSpO2 = 0;
int8_t validHeartRateFromSpO2 = 0;
int32_t calculatedHeartRateFromSpO2 = 0;


// ============================================================
// ENVIRONMENT (SHT30x)
// ============================================================
float currentTempC = 0;
bool envReadValid = false;


// ============================================================
// SOS
// ============================================================
bool sosActive = false;               // <-- the boolean to hook future integration into
unsigned long lastSOSBlink = 0;
bool sosBlinkOn = false;
const unsigned long SOS_BLINK_MS = 300;


// ============================================================
// BLE
// ============================================================
#define DEVICE_NAME "MECAI-Watch"

// Custom UUIDs for MEC-AI service
#define MECAI_SERVICE_UUID        "4d454341-4920-4845-414c-544800000001"
#define VITALS_CHAR_UUID          "4d454341-4920-4845-414c-544800000010"
#define SOS_CHAR_UUID             "4d454341-4920-4845-414c-544800000020"
#define COMMAND_CHAR_UUID         "4d454341-4920-4845-414c-544800000030"

BLEServer* pServer = nullptr;
BLECharacteristic* pVitalsChar = nullptr;
BLECharacteristic* pSOSChar = nullptr;
BLECharacteristic* pCommandChar = nullptr;

bool bleClientConnected = false;
bool bleOldClientConnected = false;
unsigned long lastBleNotify = 0;
const unsigned long BLE_NOTIFY_INTERVAL = 1000; // 1 Hz; BLE notify can delay button polling

// Forward declarations for functions used by BLE callbacks.
// These are defined later in the file but referenced from callback classes.
void markInteraction();
void updateDisplay();
void drawSOSScreen();
void setBaseStatusColor();

class MecServerCallbacks : public BLEServerCallbacks {
  void onConnect(BLEServer* server) override {
    bleClientConnected = true;
    displayDirty = true;
    Serial.println(">>> BLE client connected");
    markInteraction();
  }
  void onDisconnect(BLEServer* server) override {
    bleClientConnected = false;
    displayDirty = true;
    Serial.println(">>> BLE client disconnected - restarting advertising");
    delay(50);
    BLEDevice::startAdvertising();
  }
};

class MecCommandCallbacks : public BLECharacteristicCallbacks {
  void onWrite(BLECharacteristic* pChar) override {
    String val = pChar->getValue();
    if (val.length() > 0) {
      uint8_t cmd = val[0];
      Serial.print("BLE command received: 0x");
      Serial.println(cmd, HEX);

      switch (cmd) {
        case 0x01:  // Toggle SOS
          sosActive = !sosActive;
          if (sosActive) {
            Serial.println(">>> SOS ACTIVATED (BLE)");
            sosBlinkOn = true;
            lastSOSBlink = millis();
            drawSOSScreen();
          } else {
            Serial.println(">>> SOS CANCELED (BLE)");
            setBaseStatusColor();
            updateDisplay();
          }
          break;
        case 0x02:  // Toggle C/F
          useFahrenheit = !useFahrenheit;
          if (!sosActive) updateDisplay();
          break;
        case 0x03:  // Cycle display mode
          if (!sosActive) {
            displayMode = (DisplayMode)((displayMode + 1) % MODE_COUNT);
            updateDisplay();
          }
          break;
      }
      markInteraction();
    }
  }
};


// ============================================================
// POWER / IDLE MANAGEMENT
// ============================================================
unsigned long lastInteractionTime = 0;
bool backlightOn = true;

// Only kicks in while NOT worn AND SOS is not active.
const unsigned long BACKLIGHT_TIMEOUT_MS = 20000;   // 20s idle -> screen off
const unsigned long DEEPSLEEP_TIMEOUT_MS = 120000;  // 2 min idle -> deep sleep

void initBLE() {
  Serial.println("Initializing BLE...");
  BLEDevice::init(DEVICE_NAME);

  pServer = BLEDevice::createServer();
  pServer->setCallbacks(new MecServerCallbacks());

  BLEService* pService = pServer->createService(MECAI_SERVICE_UUID);

  // Vitals characteristic: notifies with a packed struct
  pVitalsChar = pService->createCharacteristic(
    VITALS_CHAR_UUID,
    BLECharacteristic::PROPERTY_READ | BLECharacteristic::PROPERTY_NOTIFY
  );
  pVitalsChar->addDescriptor(new BLE2902());

  // SOS characteristic: notifies on change
  pSOSChar = pService->createCharacteristic(
    SOS_CHAR_UUID,
    BLECharacteristic::PROPERTY_READ | BLECharacteristic::PROPERTY_NOTIFY
  );
  pSOSChar->addDescriptor(new BLE2902());

  // Command characteristic: writable by the phone
  pCommandChar = pService->createCharacteristic(
    COMMAND_CHAR_UUID,
    BLECharacteristic::PROPERTY_WRITE
  );
  pCommandChar->setCallbacks(new MecCommandCallbacks());

  pService->start();

  BLEAdvertising* pAdvertising = BLEDevice::getAdvertising();
  pAdvertising->addServiceUUID(MECAI_SERVICE_UUID);
  pAdvertising->setScanResponse(true);
  pAdvertising->setMinPreferred(0x06);
  pAdvertising->setMinPreferred(0x12);
  BLEDevice::startAdvertising();

  Serial.println("BLE advertising as: " DEVICE_NAME);
}

// Packed vitals struct sent over BLE (12 bytes)
// Byte layout:
//   [0-1]  uint16_t heartRate (BPM * 10, 0 = invalid)
//   [2-3]  uint16_t spo2 (% * 10, 0 = invalid)
//   [4-5]  int16_t  ambientTempC (°C * 100)
//   [6]    uint8_t  wearing (0 or 1)
//   [7]    uint8_t  sosActive (0 or 1)
//   [8]    uint8_t  displayMode
//   [9]    uint8_t  useFahrenheit (0 or 1)
//   [10-11] uint16_t reserved (0)
struct __attribute__((packed)) VitalsPacket {
  uint16_t heartRate;
  uint16_t spo2;
  int16_t  ambientTemp;
  uint8_t  wearingFlag;
  uint8_t  sosFlag;
  uint8_t  mode;
  uint8_t  fahrenheit;
  uint16_t reserved;
};

void sendBleVitals() {
  static VitalsPacket lastPacket = {};
  static bool hasLastPacket = false;

  if (!bleClientConnected) return;
  if (millis() - lastBleNotify < BLE_NOTIFY_INTERVAL) return;

  VitalsPacket pkt;
  pkt.heartRate  = (wearing && heartRateValid) ? (uint16_t)(filteredHeartRate * 10) : 0;
  pkt.spo2       = (wearing && currentSpO2 > 0) ? (uint16_t)(currentSpO2 * 10) : 0;
  pkt.ambientTemp = envReadValid ? (int16_t)(currentTempC * 100) : 0;
  pkt.wearingFlag = wearing ? 1 : 0;
  pkt.sosFlag     = sosActive ? 1 : 0;
  pkt.mode        = (uint8_t)displayMode;
  pkt.fahrenheit  = useFahrenheit ? 1 : 0;
  pkt.reserved    = 0;

  if (hasLastPacket && memcmp(&pkt, &lastPacket, sizeof(pkt)) == 0) return;

  lastBleNotify = millis();
  lastPacket = pkt;
  hasLastPacket = true;
  pVitalsChar->setValue((uint8_t*)&pkt, sizeof(pkt));
  pVitalsChar->notify();
}

void sendBleSOS() {
  if (!bleClientConnected) return;
  uint8_t val = sosActive ? 1 : 0;
  pSOSChar->setValue(&val, 1);
  pSOSChar->notify();
}

void updateBleAdvertising() {
  if (!bleClientConnected && bleOldClientConnected) {
    // Restart advertising after disconnect
    delay(100);
    BLEDevice::startAdvertising();
    Serial.println("BLE re-advertising");
  }
  bleOldClientConnected = bleClientConnected;
}


// ============================================================
// SETUP
// ============================================================
void setup() {
  Serial.begin(115200);
  delay(200);

  pinMode(TFT_I2C_POWER, OUTPUT);
  digitalWrite(TFT_I2C_POWER, HIGH);
  pinMode(TFT_BACKLITE, OUTPUT);
  digitalWrite(TFT_BACKLITE, HIGH);
  pinMode(NEOPIXEL_POWER, OUTPUT);
  digitalWrite(NEOPIXEL_POWER, HIGH);

  pinMode(BUTTON1_PIN, INPUT_PULLUP);
  pinMode(BUTTON2_PIN, INPUT_PULLUP);
  pinMode(BUTTON3_PIN, INPUT_PULLUP);

  spi.begin(TFT_SCLK, -1, TFT_MOSI, TFT_CS);
  tft.init(135, 240);
  tft.setRotation(3);
  tft.fillScreen(ST77XX_BLACK);
  tft.setTextWrap(false);

  pixel.begin();
  pixel.setBrightness(pixelBrightnessLevels[brightnessIndex]);
  setPixel(0, 0, 0);

  Wire.begin(I2C_SDA, I2C_SCL);
  Wire.setClock(400000);

  printWakeReason();
  showStartup();

  initBLE();

  Serial.println();
  Serial.println("Initializing MAX30102...");

  if (!maxSensor.begin(Wire, I2C_SPEED_FAST)) {
    Serial.println("ERROR: MAX30102 NOT FOUND");
    tft.fillScreen(ST77XX_BLACK);
    tft.setTextColor(ST77XX_RED);
    tft.setTextSize(2);
    tft.setCursor(10, 50);
    tft.println("MAX30102");
    tft.println("NOT FOUND");
    delay(1200);
  } else {
    maxSensorFound = true;
    Serial.println("MAX30102 OK");
    maxSensor.setup(0x1F, 4, 2, 100, 411, 4096);
    maxSensor.setPulseAmplitudeRed(0x1F);
    maxSensor.setPulseAmplitudeIR(0x1F);
    maxSensor.setPulseAmplitudeGreen(0);
  }

  Serial.println("Initializing SHT30x...");
  if (!sht31.begin(0x44)) {          // most SHT30x breakouts default to 0x44
    Serial.println("ERROR: SHT30x NOT FOUND (trying 0x45)");
    if (!sht31.begin(0x45)) {
      Serial.println("ERROR: SHT30x NOT FOUND");
      sht31Found = false;
    } else {
      sht31Found = true;
    }
  } else {
    sht31Found = true;
  }
  Serial.println(sht31Found ? "SHT30x OK" : "SHT30x NOT FOUND");

  clearHeartHistory();
  clearSpO2Buffer();

  lastInteractionTime = millis();
  backlightOn = true;

  tft.fillScreen(ST77XX_BLACK);
  drawHealthScreen();
}


// ============================================================
// MAIN LOOP
// ============================================================
void loop() {
  handleButtons();
  serviceMAX30102();
  updateWearDetection();

  if (millis() - lastEnvUpdate >= ENV_INTERVAL) {
    lastEnvUpdate = millis();
    updateEnvironment();
  }

  if (millis() - lastSpO2Update >= SPO2_INTERVAL) {
    lastSpO2Update = millis();
    calculateSpO2();
  }

  handleSOSState();          // <-- placeholder hook lives in here
  updateHeartbeatPixel();
  sendBleVitals();
  updateBleAdvertising();
  updateIdlePower();

  if (backlightOn && displayDirty && millis() - lastDisplayUpdate >= DISPLAY_INTERVAL) {
    lastDisplayUpdate = millis();
    updateDisplay();
  }
}


// ============================================================
// MAX30102 SERVICE
// ============================================================
void serviceMAX30102() {
  if (!maxSensorFound) return;
  maxSensor.check();

  uint8_t samplesProcessed = 0;
  while (maxSensor.available() && samplesProcessed++ < 8) {
    uint32_t red = maxSensor.getFIFORed();
    uint32_t ir  = maxSensor.getFIFOIR();

    if (spo2SampleCount < SPO2_BUFFER_SIZE) {
      irBuffer[spo2SampleCount] = ir;
      redBuffer[spo2SampleCount] = red;
      spo2SampleCount++;
    } else {
      for (int i = 0; i < SPO2_BUFFER_SIZE - 1; i++) {
        irBuffer[i] = irBuffer[i + 1];
        redBuffer[i] = redBuffer[i + 1];
      }
      irBuffer[SPO2_BUFFER_SIZE - 1] = ir;
      redBuffer[SPO2_BUFFER_SIZE - 1] = red;
    }

    processHeartBeat(ir);
    maxSensor.nextSample();
  }
}


// ============================================================
// HEART RATE
// ============================================================
void processHeartBeat(uint32_t irValue) {
  if (!wearing) return;

  if (checkForBeat(irValue)) {
    long now = millis();
    long delta = now - lastBeatTime;
    lastBeatTime = now;

    if (delta > 250 && delta < 1500) {
      int bpm = 60000 / delta;

      if (bpm >= 40 && bpm <= 220) {
        currentHeartRate = bpm;
        addHeartRate(bpm);
        filteredHeartRate = getAverageHeartRate();
        heartRateValid = true;
        displayDirty = true;

        if (!sosActive) {   // SOS blink owns the LED while active
          heartbeatFlashActive = true;
          heartbeatFlashUntil = millis() + HEARTBEAT_FLASH_MS;
          pixel.setPixelColor(0, pixel.Color(255, 0, 0));
          pixel.show();
        }

        Serial.print("Heart rate: ");
        Serial.println(filteredHeartRate);
      }
    }
  }
}

void addHeartRate(int bpm) {
  hrHistory[hrHistoryIndex] = bpm;
  hrHistoryIndex++;
  if (hrHistoryIndex >= HR_HISTORY_SIZE) hrHistoryIndex = 0;
  if (hrHistoryCount < HR_HISTORY_SIZE) hrHistoryCount++;
}

int getAverageHeartRate() {
  if (hrHistoryCount == 0) return 0;
  long total = 0;
  for (int i = 0; i < hrHistoryCount; i++) total += hrHistory[i];
  return total / hrHistoryCount;
}

void updateHeartbeatPixel() {
  if (sosActive) return;  // SOS blink logic handles the LED instead
  if (heartbeatFlashActive && millis() > heartbeatFlashUntil) {
    heartbeatFlashActive = false;
    setBaseStatusColor();
  }
}


// ============================================================
// SPO2
// ============================================================
void calculateSpO2() {
  if (!wearing) {
    currentSpO2 = 0;
    return;
  }

  if (spo2SampleCount < SPO2_BUFFER_SIZE) return;

  maxim_heart_rate_and_oxygen_saturation(
    irBuffer, SPO2_BUFFER_SIZE, redBuffer,
    &calculatedSpO2, &validSpO2,
    &calculatedHeartRateFromSpO2, &validHeartRateFromSpO2
  );

  if (validSpO2 && calculatedSpO2 >= 70 && calculatedSpO2 <= 100) {
    if (currentSpO2 != calculatedSpO2) displayDirty = true;
    currentSpO2 = calculatedSpO2;
    Serial.print("SpO2: ");
    Serial.print(currentSpO2);
    Serial.println("%");
  }
}


// ============================================================
// WEAR DETECTION
// ============================================================
void updateWearDetection() {
  if (!maxSensorFound) return;
  uint32_t ir = maxSensor.getIR();

  if (!wearing) {
    if (ir > IR_WEAR_THRESHOLD) {
      if (wearStartTime == 0) wearStartTime = millis();

      if (millis() - wearStartTime >= WEAR_CONFIRM_TIME) {
        wearing = true;
        displayDirty = true;
        wearStartTime = 0;
        removalStartTime = 0;

        Serial.println(">>> MEC-AI WORN");
        setBaseStatusColor();
        markInteraction();
      }
    } else {
      wearStartTime = 0;
    }
  } else {
    if (ir < IR_WEAR_THRESHOLD) {
      if (removalStartTime == 0) removalStartTime = millis();

      if (millis() - removalStartTime >= REMOVE_CONFIRM_TIME) {
        wearing = false;
        displayDirty = true;
        removalStartTime = 0;
        wearStartTime = 0;
        heartRateValid = false;
        filteredHeartRate = 0;
        currentSpO2 = 0;

        clearHeartHistory();
        clearSpO2Buffer();

        Serial.println(">>> MEC-AI REMOVED");
        setBaseStatusColor();
        markInteraction();
      }
    } else {
      removalStartTime = 0;
    }
  }
}

void setBaseStatusColor() {
  if (sosActive) return;  // never override the SOS blink color
  if (wearing) {
    setPixel(0, 80, 120);  // teal - worn, monitoring
  } else {
    setPixel(0, 0, 0);     // off - not worn
  }
}


// ============================================================
// BUFFER RESETS
// ============================================================
void clearSpO2Buffer() {
  spo2SampleCount = 0;
  for (int i = 0; i < SPO2_BUFFER_SIZE; i++) {
    irBuffer[i] = 0;
    redBuffer[i] = 0;
  }
}

void clearHeartHistory() {
  for (int i = 0; i < HR_HISTORY_SIZE; i++) hrHistory[i] = 0;
  hrHistoryIndex = 0;
  hrHistoryCount = 0;
  lastBeatTime = 0;
}


// ============================================================
// ENVIRONMENT (SHT30x)
// ============================================================
void updateEnvironment() {
  if (!sht31Found) return;

  float t = sht31.readTemperature();

  if (!isnan(t)) {
    if (!envReadValid || currentTempC != t) displayDirty = true;
    currentTempC = t;
    envReadValid = true;
  } else {
    if (envReadValid) displayDirty = true;
    envReadValid = false;
    Serial.println("SHT30x read failed");
  }
}

float displayTemp() {
  return useFahrenheit ? (currentTempC * 9.0 / 5.0 + 32.0) : currentTempC;
}


// ============================================================
// DISPLAY UPDATE
// ============================================================
void updateDisplay() {
  displayDirty = false;
  if (sosActive) {
    drawSOSScreen();
    return;
  }
  if (displayMode == HEALTH_MODE) drawHealthScreen();
  else drawEnvScreen();
}

void drawModeDots() {
  int totalModes = MODE_COUNT;
  int spacing = 12;
  int startX = (240 - (totalModes - 1) * spacing) / 2;
  int y = 128;

  for (int i = 0; i < totalModes; i++) {
    if (i == displayMode) {
      tft.fillCircle(startX + i * spacing, y, 2, ST77XX_CYAN);
    } else {
      tft.drawCircle(startX + i * spacing, y, 2, ST77XX_WHITE);
    }
  }
}


// ============================================================
// HEALTH SCREEN
// ============================================================
void drawHealthScreen() {
  tft.fillScreen(ST77XX_BLACK);

  tft.setTextSize(2);
  tft.setTextColor(ST77XX_WHITE);
  tft.setCursor(72, 5);
  tft.print("MEC-AI");

  tft.setTextSize(1);
  tft.setCursor(7, 10);
  if (wearing) {
    tft.setTextColor(ST77XX_GREEN);
    tft.print("* WORN");
  } else {
    tft.setTextColor(ST77XX_RED);
    tft.print("* OFF");
  }

  tft.setCursor(180, 10);
  if (bleClientConnected) {
    tft.setTextColor(ST77XX_CYAN);
    tft.print("BLE:OK");
  } else {
    tft.setTextColor(ST77XX_WHITE);
    tft.print("BLE:--");
  }

  tft.drawLine(5, 28, 235, 28, ST77XX_WHITE);

  // Heart rate
  tft.setTextColor(ST77XX_RED);
  tft.setTextSize(1);
  tft.setCursor(20, 38);
  tft.print("HEART RATE");

  tft.setTextSize(4);
  tft.setCursor(15, 53);
  if (wearing && heartRateValid) tft.print(filteredHeartRate);
  else tft.print("--");

  tft.setTextSize(1);
  tft.setCursor(82, 76);
  tft.print("BPM");

  // SpO2
  tft.setTextColor(ST77XX_CYAN);
  tft.setTextSize(1);
  tft.setCursor(150, 38);
  tft.print("SpO2");

  tft.setTextSize(4);
  tft.setCursor(140, 53);
  if (wearing && currentSpO2 > 0) tft.print(currentSpO2);
  else tft.print("--");

  tft.setTextSize(1);
  tft.setCursor(205, 76);
  tft.print("%");

  tft.drawLine(5, 93, 235, 93, ST77XX_WHITE);
  tft.setTextColor(ST77XX_WHITE);
  tft.setCursor(20, 106);
  if (!wearing) tft.print("PLACE MEC-AI ON WRIST");
  else tft.print("MONITORING");

  drawModeDots();
}


// ============================================================
// ENVIRONMENT SCREEN
// ============================================================
void drawEnvScreen() {
  tft.fillScreen(ST77XX_BLACK);

  tft.setTextColor(ST77XX_WHITE);
  tft.setTextSize(2);
  tft.setCursor(50, 5);
  tft.print("TEMPERATURE");

  tft.drawLine(5, 28, 235, 28, ST77XX_WHITE);

  if (!sht31Found) {
    tft.setTextColor(ST77XX_RED);
    tft.setTextSize(2);
    tft.setCursor(30, 55);
    tft.print("SENSOR NOT FOUND");
    drawModeDots();
    return;
  }

  tft.setTextColor(ST77XX_ORANGE);
  tft.setTextSize(6);
  char tempTxt[8];
  if (envReadValid) {
    dtostrf(displayTemp(), 4, 1, tempTxt);
  } else {
    strcpy(tempTxt, "--");
  }
  int16_t x1, y1; uint16_t w, h;
  tft.getTextBounds(tempTxt, 0, 0, &x1, &y1, &w, &h);
  tft.setCursor((240 - (int)w) / 2, 40);
  tft.print(tempTxt);

  tft.setTextSize(2);
  tft.setCursor((240 + (int)w) / 2 + 6, 40 + (int)h - 16);
  tft.print(useFahrenheit ? "F" : "C");

  tft.drawLine(5, 93, 235, 93, ST77XX_WHITE);
  tft.setTextColor(ST77XX_WHITE);
  tft.setTextSize(1);
  tft.setCursor(20, 106);
  tft.print("BTN2: toggle C/F");

  drawModeDots();
}


// ============================================================
// SOS SCREEN
// ============================================================
void drawSOSScreen() {
  tft.fillScreen(sosBlinkOn ? ST77XX_RED : ST77XX_BLACK);

  tft.setTextColor(sosBlinkOn ? ST77XX_BLACK : ST77XX_RED);
  tft.setTextSize(4);
  tft.setCursor(85, 45);
  tft.print("SOS");

  tft.setTextSize(1);
  tft.setCursor(65, 100);
  tft.print("PRESS BTN3 TO CANCEL");
}


// ============================================================
// SOS HANDLING
// ============================================================
void handleSOSState() {
  if (!sosActive) return;

  // Non-blocking blink for both the screen and the NeoPixel
  if (millis() - lastSOSBlink >= SOS_BLINK_MS) {
    lastSOSBlink = millis();
    sosBlinkOn = !sosBlinkOn;

    pixel.setPixelColor(0, sosBlinkOn ? pixel.Color(255, 0, 0) : pixel.Color(0, 0, 0));
    pixel.show();

    // Force a screen redraw on every blink toggle regardless of DISPLAY_INTERVAL
    drawSOSScreen();
  }

  // --------------------------------------------------------
  // TODO: hook actual SOS transmission logic here.
  // sosActive is a plain boolean specifically so this is easy
  // to wire into later - e.g.:
  //   - send a BLE notification / write a GATT characteristic
  //   - trigger a buzzer or vibration motor
  //   - transmit over LoRa/GSM to an emergency contact
  //   - log a timestamped event to SD/flash
  // Keep this section non-blocking (no delay()) to stay
  // consistent with the rest of the loop.
  // --------------------------------------------------------
}


// ============================================================
// BUTTON HANDLING
// ============================================================
void handleButtons() {
  checkButton(BUTTON1_PIN, 0);
  checkButton(BUTTON2_PIN, 1);
  checkButton(BUTTON3_PIN, 2);

  checkLongPress(0);
  checkLongPress(1);
  // Button 3 (index 2) intentionally has no long-press behavior - SOS only.
}

void checkButton(int pin, int index) {
  bool reading = digitalRead(pin);

  if (reading != lastRawState[index]) {
    lastDebounce[index] = millis();
  }

  if (millis() - lastDebounce[index] >= debounceDelay) {
    if (reading != debouncedState[index]) {
      debouncedState[index] = reading;

      if (debouncedState[index] == LOW) {
        pressStartTime[index] = millis();
        longPressFired[index] = false;
        markInteraction();
        onButtonPress(index);
      }
    }
  }

  lastRawState[index] = reading;
}

void checkLongPress(int index) {
  if (debouncedState[index] == LOW && !longPressFired[index]) {
    if (millis() - pressStartTime[index] >= LONG_PRESS_MS) {
      longPressFired[index] = true;
      onLongPress(index);
    }
  }
}


// ============================================================
// BUTTON ACTIONS (short press)
// ============================================================
void onButtonPress(int index) {
  switch (index) {

    case 0:  // Button 1: cycle display mode
      if (!sosActive) {
        displayMode = (DisplayMode)((displayMode + 1) % MODE_COUNT);
        updateDisplay();
      }
      Serial.println("Button 1: mode changed");
      break;

    case 1:  // Button 2 short: toggle Celsius/Fahrenheit
      useFahrenheit = !useFahrenheit;
      if (!sosActive) updateDisplay();
      Serial.println("Button 2: unit toggled");
      break;

    case 2:  // Button 3: SOS toggle - the ONLY thing this button does
      sosActive = !sosActive;
      if (sosActive) {
        Serial.println(">>> SOS ACTIVATED");
        sendBleSOS();
        sosBlinkOn = true;
        lastSOSBlink = millis();
        drawSOSScreen();
      } else {
        Serial.println(">>> SOS CANCELED");
        sendBleSOS();
        setBaseStatusColor();
        updateDisplay();
      }
      break;
  }
}


// ============================================================
// BUTTON ACTIONS (long press)
// ============================================================
void onLongPress(int index) {
  switch (index) {

    case 1:  // Button 2 long: cycle brightness
      brightnessIndex = (brightnessIndex + 1) % 3;
      pixel.setBrightness(pixelBrightnessLevels[brightnessIndex]);
      if (!sosActive) setBaseStatusColor();
      Serial.print("Button 2 (long): brightness -> ");
      Serial.println(pixelBrightnessLevels[brightnessIndex]);
      break;

    // Button 1 and Button 3 have no long-press action.
  }
}


// ============================================================
// IDLE POWER MANAGEMENT
// ============================================================
void markInteraction() {
  lastInteractionTime = millis();

  if (!backlightOn) {
    digitalWrite(TFT_BACKLITE, HIGH);
    backlightOn = true;
    updateDisplay();
  }
}

void updateIdlePower() {
  // Never dim or sleep while worn, or while SOS is active.
  if (wearing || sosActive) return;

  unsigned long idleFor = millis() - lastInteractionTime;

  if (backlightOn && idleFor >= BACKLIGHT_TIMEOUT_MS) {
    digitalWrite(TFT_BACKLITE, LOW);
    backlightOn = false;
    Serial.println(">>> Backlight off (idle, not worn)");
  }

  // Never enter deep sleep while phone is connected over BLE
  if (!bleClientConnected && idleFor >= DEEPSLEEP_TIMEOUT_MS) {
    goToSleep();
  }
}

void goToSleep() {
  Serial.println(">>> Entering deep sleep - press any button to wake");

  digitalWrite(TFT_BACKLITE, LOW);
  setPixel(0, 0, 0);
  digitalWrite(NEOPIXEL_POWER, LOW);

  BLEDevice::deinit(true);  // clean shutdown before deep sleep

  rtc_gpio_pullup_en((gpio_num_t)BUTTON1_PIN);
  rtc_gpio_pullup_en((gpio_num_t)BUTTON2_PIN);
  rtc_gpio_pullup_en((gpio_num_t)BUTTON3_PIN);

  uint64_t wakeMask = (1ULL << BUTTON1_PIN) | (1ULL << BUTTON2_PIN) | (1ULL << BUTTON3_PIN);
  esp_sleep_enable_ext1_wakeup(wakeMask, ESP_EXT1_WAKEUP_ANY_LOW);

  BLEDevice::deinit(true);
  delay(50);
  esp_deep_sleep_start();
}

void printWakeReason() {
  esp_sleep_wakeup_cause_t cause = esp_sleep_get_wakeup_cause();
  if (cause == ESP_SLEEP_WAKEUP_EXT1) {
    Serial.println(">>> Woke from deep sleep (button press)");
  }
}


// ============================================================
// STARTUP
// ============================================================
void showStartup() {
  const uint16_t palette[] = {
    ST77XX_RED, ST77XX_ORANGE, ST77XX_YELLOW,
    ST77XX_GREEN, ST77XX_CYAN, ST77XX_BLUE, ST77XX_MAGENTA
  };
  const int paletteSize = 7;
  const char* word = "MEC-AI";
  const int len = 6;

  tft.fillScreen(ST77XX_BLACK);

  // ---- Stage 1: rings burst outward from center ----
  int cx = 120, cy = 60;
  for (int r = 4; r <= 130; r += 6) {
    tft.drawCircle(cx, cy, r, palette[(r / 6) % paletteSize]);
    delay(10);
  }
  tft.fillScreen(ST77XX_BLACK);

  // ---- Stage 2: letters pop in one at a time, each a different color ----
  const int charWidth = 6 * 4;              // GFX default font cell at size 4
  const int totalWidth = charWidth * len;
  const int startX = (240 - totalWidth) / 2;
  const int y = 50;

  for (int i = 0; i < len; i++) {
    char c[2] = { word[i], '\0' };
    uint16_t color = palette[i % paletteSize];

    for (int s = 1; s <= 4; s++) {
      tft.fillRect(startX + i * charWidth, y - 8, charWidth, 44, ST77XX_BLACK);
      tft.setTextSize(s);
      tft.setTextColor(color);
      int offset = (4 - s) * 3;
      tft.setCursor(startX + i * charWidth + offset, y + offset);
      tft.print(c);
      delay(16);
    }
    delay(35);
  }

  delay(150);

  // ---- Stage 3: pulse the whole word through the color palette ----
  tft.setTextSize(4);
  for (int p = 0; p < 2; p++) {
    for (int ci = 0; ci < paletteSize; ci++) {
      tft.setCursor(startX, y);
      tft.setTextColor(palette[ci], ST77XX_BLACK);  // opaque bg redraws cleanly
      tft.print(word);
      delay(40);
    }
  }

  // ---- Stage 4: settle-flicker into steady white ----
  tft.setCursor(startX, y);
  tft.setTextColor(ST77XX_BLACK, ST77XX_BLACK);
  tft.print(word);
  delay(50);
  tft.setCursor(startX, y);
  tft.setTextColor(ST77XX_WHITE, ST77XX_BLACK);
  tft.print(word);

  // ---- Stage 5: sparkle accents ----
  randomSeed(esp_random());
  for (int i = 0; i < 18; i++) {
    int sx = random(10, 230);
    int sy = random(10, 125);
    uint16_t c = palette[random(0, paletteSize)];
    tft.fillCircle(sx, sy, 1, c);
    delay(10);
  }

  // ---- Stage 6: BLE indicator ----
  tft.setTextSize(1);
  tft.setTextColor(ST77XX_CYAN);
  int bleTextWidth = 6 * 17;  // "BLE: MECAI-Watch" is 17 chars
  tft.setCursor((240 - bleTextWidth) / 2, 115);
  tft.print("BLE: " DEVICE_NAME);

  delay(500);
}


// ============================================================
// NEOPIXEL
// ============================================================
void setPixel(uint8_t r, uint8_t g, uint8_t b) {
  pixel.setPixelColor(0, pixel.Color(r, g, b));
  pixel.show();
}
