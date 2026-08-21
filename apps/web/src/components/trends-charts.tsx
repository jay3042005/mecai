"use client";

import { useEffect, useRef, useState } from "react";
import { show, type VitalsReading } from "@/lib/api";
import { usePrefersReducedMotion } from "@/lib/use-reduced-motion";
import { Table, Activity, Thermometer, Droplet, HeartPulse } from "lucide-react";

export function TimeHorizonPicker({
  value,
  onChange,
}: {
  value: string;
  onChange: (val: string) => void;
}) {
  const options = ["24h", "7d", "30d"];
  return (
    <div className="flex gap-2 mb-6">
      {options.map((opt) => (
        <button
          key={opt}
          onClick={() => onChange(opt)}
          className={`px-4 py-1.5 rounded-full text-[13px] font-medium transition-all active:scale-95 ${
            value === opt
              ? "bg-[var(--mec-s1)] text-white"
              : "bg-[color-mix(in_srgb,var(--mec-card)_80%,transparent)] text-[var(--mec-ink-secondary)] hover:bg-[color-mix(in_srgb,var(--mec-card)_60%,transparent)]"
          }`}
        >
          {opt}
        </button>
      ))}
    </div>
  );
}

interface ChartConfig {
  title: string;
  icon: React.ElementType;
  series: {
    key: keyof VitalsReading;
    colorVar: string;
    label: string;
  }[];
  minY?: number;
  maxY?: number;
  referenceBand?: [number, number];
  referenceLine?: number;
}

const CHARTS: ChartConfig[] = [
  {
    title: "Blood Pressure",
    icon: Activity,
    series: [
      { key: "systolic_mmhg", colorVar: "--mec-s1", label: "Systolic" },
      { key: "diastolic_mmhg", colorVar: "--mec-s2", label: "Diastolic" },
    ],
    referenceLine: 130, // Reference for systolic
    // We'll draw 130/80 as reference lines manually in the component
  },
  {
    title: "Heart Rate",
    icon: HeartPulse,
    series: [{ key: "heart_rate_bpm", colorVar: "--mec-s1", label: "HR" }],
    referenceBand: [60, 100],
  },
  {
    title: "SpO₂",
    icon: Droplet,
    series: [{ key: "spo2_pct", colorVar: "--mec-s1", label: "SpO₂" }],
    referenceLine: 95,
  },
  {
    title: "Temperature",
    icon: Thermometer,
    series: [{ key: "temperature_c", colorVar: "--mec-s1", label: "Temp" }],
    referenceBand: [36.1, 37.2],
  },
];

function SingleChart({
  config,
  readings,
}: {
  config: ChartConfig;
  readings: VitalsReading[];
}) {
  const canvasRef = useRef<HTMLCanvasElement>(null);
  const [showTable, setShowTable] = useState(false);
  const reducedMotion = usePrefersReducedMotion();

  // Whether any reading carries a value for this chart's series. A device with no
  // pressure sensor produces rows where `systolic_mmhg` is null throughout — a
  // real and expected state that must read as "not measured", never as a flat line
  // at zero.
  const hasData = readings.some((r) =>
    config.series.some((serie) => r[serie.key] != null),
  );


  useEffect(() => {
    const canvas = canvasRef.current;
    if (!canvas || showTable || readings.length === 0 || !hasData) return;

    const ctx = canvas.getContext("2d");
    if (!ctx) return;

    // Handle high DPI displays
    const dpr = window.devicePixelRatio || 1;
    const rect = canvas.getBoundingClientRect();
    canvas.width = rect.width * dpr;
    canvas.height = rect.height * dpr;
    ctx.scale(dpr, dpr);

    const width = rect.width;
    const height = rect.height;
    const padding = { top: 20, right: 50, bottom: 20, left: 40 };
    const plotWidth = width - padding.left - padding.right;
    const plotHeight = height - padding.top - padding.bottom;

    const style = getComputedStyle(canvas);
    const gridlineColor = style.getPropertyValue("--mec-gridline") || "#e5e5e5";
    const inkPrimary = style.getPropertyValue("--mec-ink-primary") || "#0d0d0d";
    const inkSecondary = style.getPropertyValue("--mec-ink-secondary") || "#898781";

    ctx.clearRect(0, 0, width, height);

    // Calculate Y range
    let minY = Infinity;
    let maxY = -Infinity;

    readings.forEach((r) => {
      config.series.forEach((s) => {
        const val = r[s.key] as number | null;
        if (val !== null) {
          minY = Math.min(minY, val);
          maxY = Math.max(maxY, val);
        }
      });
    });

    if (config.referenceBand) {
      minY = Math.min(minY, config.referenceBand[0]);
      maxY = Math.max(maxY, config.referenceBand[1]);
    }
    if (config.referenceLine) {
      if (config.title === "Blood Pressure") {
        maxY = Math.max(maxY, 130);
        minY = Math.min(minY, 80);
      } else {
        minY = Math.min(minY, config.referenceLine);
        maxY = Math.max(maxY, config.referenceLine);
      }
    }

    // Add padding to Y range
    const yRange = maxY - minY || 10;
    minY = Math.max(0, minY - yRange * 0.1);
    maxY = maxY + yRange * 0.1;

    // Helper functions.
    //
    // X is proportional to *time*, not to array index. Readings arrive from the
    // archive at whatever cadence the device managed — a phone that was offline
    // overnight leaves an eight-hour gap between consecutive rows. Spacing by
    // index would draw that gap identically to a one-minute interval, so the
    // chart would silently misrepresent when everything happened. Even spacing
    // looked correct only because the synthetic series it used to plot was
    // itself evenly spaced.
    const times = readings.map((r) => new Date(r.measured_at).getTime());
    const tMin = times[0];
    const tMax = times[times.length - 1];
    const tSpan = tMax - tMin;

    const getX = (index: number) =>
      tSpan > 0
        ? padding.left + ((times[index] - tMin) / tSpan) * plotWidth
        // All readings share a timestamp (or there is only one): fall back to
        // even spacing rather than dividing by zero.
        : padding.left + (index / Math.max(1, readings.length - 1)) * plotWidth;

    const getY = (val: number) => padding.top + plotHeight - ((val - minY) / (maxY - minY)) * plotHeight;

    // Draw Grid and Ticks
    ctx.strokeStyle = gridlineColor;
    ctx.lineWidth = 1;
    ctx.font = "400 12px tabular-nums, sans-serif";
    ctx.fillStyle = inkSecondary;
    ctx.textAlign = "right";
    ctx.textBaseline = "middle";

    const ySteps = 4;
    for (let i = 0; i <= ySteps; i++) {
      const val = minY + (i / ySteps) * (maxY - minY);
      const y = getY(val);
      
      ctx.beginPath();
      ctx.moveTo(padding.left, y);
      ctx.lineTo(width - padding.right, y);
      ctx.stroke();

      ctx.fillText(val.toFixed(0), padding.left - 8, y);
    }

    // Draw Reference Bands/Lines
    ctx.strokeStyle = inkSecondary;
    ctx.setLineDash([4, 4]);
    if (config.referenceBand) {
      const [refMin, refMax] = config.referenceBand;
      const yMin = getY(refMin);
      const yMax = getY(refMax);
      
      ctx.beginPath();
      ctx.moveTo(padding.left, yMin);
      ctx.lineTo(width - padding.right, yMin);
      ctx.stroke();
      
      ctx.beginPath();
      ctx.moveTo(padding.left, yMax);
      ctx.lineTo(width - padding.right, yMax);
      ctx.stroke();
    } else if (config.referenceLine) {
      if (config.title === "Blood Pressure") {
        // Draw 130 and 80
        const ySys = getY(130);
        const yDia = getY(80);
        ctx.beginPath();
        ctx.moveTo(padding.left, ySys);
        ctx.lineTo(width - padding.right, ySys);
        ctx.stroke();
        
        ctx.beginPath();
        ctx.moveTo(padding.left, yDia);
        ctx.lineTo(width - padding.right, yDia);
        ctx.stroke();
      } else {
        const yLine = getY(config.referenceLine);
        ctx.beginPath();
        ctx.moveTo(padding.left, yLine);
        ctx.lineTo(width - padding.right, yLine);
        ctx.stroke();
      }
    }
    ctx.setLineDash([]);

    // Draw Series
    config.series.forEach((s) => {
      const rawColor = style.getPropertyValue(s.colorVar).trim();
      const color = rawColor || (s.colorVar === "--mec-s2" ? "#9ec5f4" : "#3987e5");
      
      const validPoints: { x: number; y: number; val: number }[] = [];
      readings.forEach((r, i) => {
        const val = r[s.key] as number | null;
        if (val !== null && val !== undefined) {
          validPoints.push({ x: getX(i), y: getY(val), val });
        }
      });

      if (validPoints.length === 0) return;

      // Area fill with standard canvas alpha
      ctx.save();
      ctx.beginPath();
      ctx.moveTo(validPoints[0].x, padding.top + plotHeight);
      validPoints.forEach((p) => ctx.lineTo(p.x, p.y));
      ctx.lineTo(validPoints[validPoints.length - 1].x, padding.top + plotHeight);
      ctx.closePath();
      ctx.globalAlpha = 0.12;
      ctx.fillStyle = color;
      ctx.fill();
      ctx.restore();

      // Line
      ctx.beginPath();
      ctx.strokeStyle = color;
      ctx.lineWidth = 2;
      validPoints.forEach((p, i) => {
        if (i === 0) ctx.moveTo(p.x, p.y);
        else ctx.lineTo(p.x, p.y);
      });
      ctx.stroke();

      // Direct Label (last data point)
      const lastPoint = validPoints[validPoints.length - 1];
      ctx.fillStyle = inkPrimary.trim() || "#ffffff";
      ctx.textAlign = "left";
      ctx.font = "500 12px tabular-nums, sans-serif";
      ctx.fillText(lastPoint.val.toFixed(s.key === "temperature_c" ? 1 : 0), lastPoint.x + 8, lastPoint.y);
      
      // Point marker: 8px, with a 2px ring in the surface colour so it stays
      // legible where it crosses the line or a reference rule.
      ctx.beginPath();
      ctx.fillStyle = color;
      ctx.arc(lastPoint.x, lastPoint.y, 4, 0, Math.PI * 2);
      ctx.fill();
      ctx.lineWidth = 2;
      ctx.strokeStyle = style.getPropertyValue("--mec-card").trim() || "#1a1a19";
      ctx.stroke();
    });

  }, [readings, config, showTable, reducedMotion, hasData]);

  const Icon = config.icon;

  return (
    <div className="bg-[var(--mec-card)] rounded-[24px] p-6 shadow-sm ring-1 ring-[var(--mec-hairline)] mb-4">
      <div className="flex justify-between items-center mb-4">
        <div className="flex items-center gap-2">
          <Icon className="w-5 h-5 text-[var(--mec-ink-secondary)]" />
          <h3 className="text-[18px] font-[600] text-[var(--mec-ink-primary)]">
            {config.title}
          </h3>
        </div>
        <button
          onClick={() => setShowTable(!showTable)}
          className="p-2 rounded-full hover:bg-[color-mix(in_srgb,var(--mec-ink-primary)_8%,transparent)] transition-all active:scale-95"
          aria-label="Toggle table view"
        >
          <Table className="w-4 h-4 text-[var(--mec-ink-secondary)]" />
        </button>
      </div>

      <div className="relative w-full h-[140px] md:h-[180px]">
        {showTable ? (
          <div className="overflow-auto h-full text-[13px]">
            <table className="w-full text-left">
              <thead>
                <tr className="text-[var(--mec-ink-secondary)]">
                  <th className="pb-2 font-medium">Time</th>
                  {config.series.map((s) => (
                    <th key={s.key} className="pb-2 font-medium">{s.label}</th>
                  ))}
                </tr>
              </thead>
              <tbody className="tabular-nums">
                {readings.map((r, i) => (
                  <tr key={i} className="border-t border-[var(--mec-hairline)]">
                    <td className="py-2">{new Date(r.measured_at).toLocaleTimeString()}</td>
                    {config.series.map((s) => (
                      <td key={s.key} className="py-2">
                        {show(r[s.key] as number | null, 1)}
                      </td>
                    ))}
                  </tr>
                )).reverse()}
              </tbody>
            </table>
          </div>
        ) : hasData ? (
          <canvas
            ref={canvasRef}
            className="absolute inset-0 w-full h-full"
            style={{ width: "100%", height: "100%" }}
          />
        ) : (
          /* An empty chart says "no data", which is true. It replaces a blank
             canvas that read as a rendering failure — and is emphatically better
             than the synthetic series the dashboard used to invent here, whose
             fabricated points were indistinguishable from measurements. */
          <div className="flex h-full flex-col items-center justify-center gap-1 text-center">
            <p className="text-[13px] font-medium text-[var(--mec-ink-secondary)]">
              No {config.title.toLowerCase()} in this period
            </p>
            <p className="text-[12px] text-[var(--mec-ink-muted)]">
              {readings.length === 0
                ? "This device has not synced readings for the selected range."
                : "The device does not report this measurement."}
            </p>
          </div>
        )}
      </div>
    </div>
  );
}

export interface TrendsChartsComponentProps {
  /** Series of readings, oldest first. */
  readings: VitalsReading[];
  /** Loading state — hold previous at reduced opacity. */
  loading?: boolean;
  horizon?: string;
  onHorizonChange?: (horizon: string) => void;
}

export default function TrendsCharts({
  readings,
  loading = false,
  horizon: controlledHorizon,
  onHorizonChange,
}: TrendsChartsComponentProps) {
  const [internalHorizon, setInternalHorizon] = useState("24h");
  const horizon = controlledHorizon ?? internalHorizon;
  const setHorizon = (val: string) => {
    setInternalHorizon(val);
    onHorizonChange?.(val);
  };
  const reducedMotion = usePrefersReducedMotion();

  return (
    <div
      className={`w-full transition-opacity ${
        reducedMotion ? "duration-0" : "duration-[900ms]"
      } ${loading ? "opacity-50" : "opacity-100"}`}
    >
      <div className="flex items-center justify-between mb-4">
        <div>
          <h3 className="text-lg font-bold" style={{ color: "var(--mec-ink-primary)" }}>
            Longitudinal Vitals Trends
          </h3>
          <p className="text-xs" style={{ color: "var(--mec-ink-muted)" }}>
            Small-multiples sensor monitoring over time
          </p>
        </div>
        <TimeHorizonPicker value={horizon} onChange={setHorizon} />
      </div>
      
      <div className="grid grid-cols-1 md:grid-cols-2 gap-4">
        {CHARTS.map((config) => (
          <SingleChart key={config.title} config={config} readings={readings} />
        ))}
      </div>
    </div>
  );
}
