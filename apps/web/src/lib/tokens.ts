// GENERATED FILE — DO NOT EDIT.
// Source: packages/tokens/tokens.json  (spec: docs/design.md §3)
// Regenerate: node packages/tokens/generate.mjs
//
export const surface = {
  "dark": {
    "page": "#0d0d0d",
    "card": "#1a1a19",
    "elevated": "#242422",
    "inkPrimary": "#ffffff",
    "inkSecondary": "#c3c2b7",
    "inkMuted": "#898781",
    "gridline": "#2c2c2a",
    "baseline": "#383835",
    "hairline": "rgba(255,255,255,0.10)"
  },
  "light": {
    "page": "#f9f9f7",
    "card": "#fcfcfb",
    "elevated": "#ffffff",
    "inkPrimary": "#0b0b0b",
    "inkSecondary": "#52514e",
    "inkMuted": "#898781",
    "gridline": "#e1e0d9",
    "baseline": "#c3c2b7",
    "hairline": "rgba(11,11,11,0.10)"
  }
} as const;

/** Risk bands carry word + icon + arc length + colour. Colour is never alone:
  * low↔high measures ΔE 4.1 under deuteranopia. See docs/design.md §4. */
export const risk = {
  "low": {
    "hex": "#0ca30c",
    "label": "Low",
    "icon": "shield-check",
    "contrastOnDark": 5.19,
    "contrastOnLight": 3.27
  },
  "moderate": {
    "hex": "#fab219",
    "label": "Moderate",
    "icon": "alert-triangle",
    "contrastOnDark": 9.49,
    "contrastOnLight": 1.79,
    "note": "Sub-3:1 on light surface. This is why the app is dark-first."
  },
  "high": {
    "hex": "#d03b3b",
    "label": "High",
    "icon": "alert-octagon",
    "contrastOnDark": 3.62,
    "contrastOnLight": 4.68
  },
  "unknown": {
    "hex": "#898781",
    "label": "Incomplete profile",
    "icon": "help-circle",
    "note": "Rendered as a dashed neutral ring. Never show a colored band from partial input."
  }
} as const;

export const alarm = {
  "hex": "#d03b3b",
  "note": "Acute SOS/alarm state. NOT a risk band — distinguished by motion + siren icon, not hue."
} as const;
export const series = {
  "s1": {
    "dark": "#3987e5",
    "light": "#2a78d6",
    "use": "Systolic; all single-series vitals"
  },
  "s2": {
    "dark": "#9ec5f4",
    "light": "#104281",
    "use": "Diastolic"
  }
} as const;
export const sequential = {
  "blue": [
    "#cde2fb",
    "#b7d3f6",
    "#9ec5f4",
    "#86b6ef",
    "#6da7ec",
    "#5598e7",
    "#3987e5",
    "#2a78d6",
    "#256abf",
    "#1c5cab",
    "#184f95",
    "#104281",
    "#0d366b"
  ]
} as const;
export const threshold = {
  "$note": "Two distinct jobs. chartReference is presentational — the hairlines and bands drawn on trend charts (docs/design.md §8). alert is clinical — the cut-points that decide an AcuteFlag's severity. Both generate into Dart and Python so an alert fires identically on device and server; a client-side copy that drifts from the server means two different answers to 'is this dangerous'.",
  "chartReference": {
    "spo2Min": {
      "value": 95,
      "unit": "%",
      "label": "95%"
    },
    "tempNormal": {
      "min": 36.1,
      "max": 37.2,
      "unit": "degC",
      "label": "36.1-37.2 C"
    },
    "bpRef": {
      "systolic": 130,
      "diastolic": 80,
      "unit": "mmHg",
      "label": "130/80"
    },
    "hrNormal": {
      "min": 60,
      "max": 100,
      "unit": "bpm",
      "label": "60-100 bpm"
    }
  },
  "alert": {
    "$note": "Alerts must fire without a network. An SpO2 of 88% is an emergency whether or not the phone has signal, so these constants live on both sides and the evaluation runs locally.",
    "spo2": {
      "warning": 95,
      "critical": 90
    },
    "heartRate": {
      "normalMin": 60,
      "normalMax": 100,
      "lowWarning": 50,
      "lowCritical": 40,
      "highWarning": 120,
      "highCritical": 150
    },
    "temperature": {
      "$note": "Body temperature only, from a contact sensor. Ambient air temperature never evaluates against these.",
      "normalMin": 36.1,
      "normalMax": 37.2,
      "feverWarning": 37.5,
      "feverCritical": 39,
      "hypothermiaCritical": 35
    },
    "bloodPressure": {
      "$note": "ACC/AHA staging. A stage fires when EITHER systolic or diastolic reaches the cut-point.",
      "stage1Systolic": 130,
      "stage1Diastolic": 80,
      "stage2Systolic": 140,
      "stage2Diastolic": 90,
      "crisisSystolic": 180,
      "crisisDiastolic": 120
    }
  },
  "plausible": {
    "$note": "Physiological-plausibility bounds, not clinical limits. A reading outside these is a sensor fault and is rejected rather than displayed.",
    "systolic": {
      "min": 50,
      "max": 300
    },
    "diastolic": {
      "min": 25,
      "max": 200
    },
    "heartRate": {
      "min": 25,
      "max": 250
    },
    "spo2": {
      "min": 50,
      "max": 100
    },
    "temperature": {
      "min": 30,
      "max": 45
    },
    "ambientTemperature": {
      "min": 0,
      "max": 60
    }
  }
} as const;
export const type = {
  "family": "Inter",
  "fallback": "system-ui, -apple-system, \"Segoe UI\", sans-serif",
  "scale": {
    "heroFigure": {
      "size": 64,
      "weight": 600,
      "tabular": false,
      "note": "Exactly one per view. Proportional figures only."
    },
    "statValue": {
      "size": 28,
      "weight": 600,
      "tabular": false
    },
    "sectionTitle": {
      "size": 18,
      "weight": 600,
      "tabular": false
    },
    "body": {
      "size": 15,
      "weight": 400,
      "tabular": false
    },
    "label": {
      "size": 13,
      "weight": 500,
      "tabular": false
    },
    "axisTick": {
      "size": 12,
      "weight": 400,
      "tabular": true,
      "note": "The ONLY place tabular-nums is correct."
    }
  }
} as const;
export const space = [2,4,6,8,12,16,20,24,32,48,64] as const;
export const radius = {
  "xs": 8,
  "sm": 12,
  "md": 16,
  "lg": 24,
  "xl": 28,
  "xxl": 32,
  "hero": 48,
  "pill": 999,
  "card": 24,
  "control": 999,
  "chip": 999,
  "ring": 999
} as const;
export const easing = {
  "standard": {
    "curve": "cubic-bezier(0.2, 0, 0, 1)",
    "use": "MD3 Emphasized. Default for every state, shape and position change."
  },
  "decelerate": {
    "curve": "cubic-bezier(0.05, 0.7, 0.1, 1)",
    "use": "MD3 Emphasized Decelerate. Elements entering the screen."
  },
  "accelerate": {
    "curve": "cubic-bezier(0.3, 0, 0.8, 0.15)",
    "use": "MD3 Emphasized Accelerate. Elements leaving the screen."
  }
} as const;
export const state = {
  "hover": 0.08,
  "focus": 0.1,
  "press": 0.12,
  "drag": 0.16,
  "disabled": 0.38
} as const;
export const elevation = {
  "raised": {
    "y": 2,
    "blur": 8,
    "color": "rgba(0,0,0,0.32)",
    "use": "FAB, snackbar"
  },
  "floating": {
    "y": 8,
    "blur": 32,
    "color": "rgba(0,0,0,0.48)",
    "use": "Bottom sheet, dialog, SOS hero"
  }
} as const;
export const motion = {
  "instant": {
    "ms": 120,
    "easing": "cubic-bezier(0,0,0.2,1)",
    "use": "Press feedback, toggles"
  },
  "fast": {
    "ms": 220,
    "easing": "cubic-bezier(0.2,0.8,0.2,1)",
    "use": "Cards, sheets, tab change"
  },
  "value": {
    "ms": 900,
    "easing": "cubic-bezier(0,0,0.2,1)",
    "use": "Number roll-up, ring fill"
  },
  "ambient": {
    "ms": 1600,
    "easing": "cubic-bezier(0.4,0,0.6,1)",
    "use": "Heartbeat pulse, live link"
  },
  "stagger": {
    "ms": 60,
    "easing": "linear",
    "use": "Per-item delay in lists/grids"
  }
} as const;
export const chart = {
  "lineWidth": 2,
  "markerMinSize": 8,
  "surfaceRing": 2,
  "surfaceGap": 2,
  "areaFillOpacity": 0.1,
  "barMaxThickness": 24,
  "barDataEndRadius": 4,
  "gridlineWidth": 1,
  "gridlineStyle": "solid",
  "minHitTarget": 24
} as const;

export type RiskBandKey = keyof typeof risk;
