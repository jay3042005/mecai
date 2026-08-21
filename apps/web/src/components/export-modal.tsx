"use client";

import { useState, useMemo } from "react";
import { X, Download, FileText, Table2 } from "lucide-react";
import { motion } from "motion/react";
import type { VitalsReading, AssessmentResponse } from "@/lib/api";
import { usePrefersReducedMotion } from "@/lib/use-reduced-motion";

interface ExportModalProps {
  patientName: string;
  readings: VitalsReading[];
  assessment: AssessmentResponse | null;
  onClose: () => void;
}

export default function ExportModal({ patientName, readings, assessment, onClose }: ExportModalProps) {
  const prefersReduced = usePrefersReducedMotion();
  const [format, setFormat] = useState<"csv" | "summary">("csv");
  
  // CSV Generation
  const csvData = useMemo(() => {
    const headers = [
      "Timestamp",
      "Systolic (mmHg)",
      "Diastolic (mmHg)",
      "Heart Rate (bpm)",
      "SpO₂ (%)",
      "Body Temp (°C)",
      "Ambient Temp (°C)",
      "Motion Artifact"
    ];
    
    const rows = readings.map(r => {
      return [
        r.measured_at,
        r.systolic_mmhg ?? "",
        r.diastolic_mmhg ?? "",
        r.heart_rate_bpm ?? "",
        r.spo2_pct ?? "",
        r.temperature_c ?? "",
        r.ambient_temp_c ?? "",
        r.motion_artifact ? "Yes" : "No"
      ].join(",");
    });
    
    return [headers.join(","), ...rows].join("\n");
  }, [readings]);

  // Summary Generation
  const summaryData = useMemo(() => {
    const date = new Date().toLocaleString();
    let text = `MEC-AI Cardiovascular Risk Screening Report\n`;
    text += `==========================================\n\n`;
    text += `Patient: ${patientName}\n`;
    text += `Date: ${date}\n\n`;
    
    if (assessment) {
      const a = assessment.assessment;
      text += `--- Risk Assessment ---\n`;
      text += `Risk Band: ${a.band}\n`;
      text += `10-Year Risk: ${a.value_pct != null ? `${a.value_pct.toFixed(1)}%` : "Incomplete profile"}\n`;
      text += `Horizon: ${a.horizon}\n`;
      text += `Confidence: ${a.confidence}\n`;
      text += `Model Version: ${a.model_version}\n\n`;
      
      if (a.factors && a.factors.length > 0) {
        text += `--- Risk Factors ---\n`;
        a.factors.forEach((f) => {
          text += `- ${f.name}: ${f.display_value} (${(f.contribution * 100).toFixed(1)}% weight, ${f.source === "device" ? "wearable sensor" : "profile questionnaire"}, ${f.modifiable ? "modifiable" : "non-modifiable"})\n`;
        });
        text += `\n`;
      }
      
      if (assessment.acute_flags && assessment.acute_flags.length > 0) {
        text += `--- Acute Flags ---\n`;
        assessment.acute_flags.forEach((f) => {
          text += `- [${f.severity.toUpperCase()}] ${f.vital}: ${f.display_value} (${f.threshold})\n  ${f.message}\n  Recommendation: ${f.recommendation}\n`;
        });
        text += `\n`;
      }

      if (assessment.notes && assessment.notes.length > 0) {
        text += `--- Notes ---\n`;
        assessment.notes.forEach((n) => {
          text += `- ${n}\n`;
        });
        text += `\n`;
      }
    } else {
      text += `No clinical assessment available.\n\n`;
    }
    
    text += `------------------------------------------\n`;
    text += `Disclaimer: Screening indicator, not a diagnosis. Consult a physician.\n`;
    
    return text;
  }, [patientName, assessment]);

  const handleDownload = () => {
    const data = format === "csv" ? csvData : summaryData;
    const type = format === "csv" ? "text/csv;charset=utf-8;" : "text/plain;charset=utf-8;";
    const extension = format === "csv" ? "csv" : "txt";
    const dateStr = new Date().toISOString().split("T")[0];
    const filename = `mecai-${format === "csv" ? "readings" : "report"}-${patientName.replace(/\s+/g, "_").toLowerCase()}-${dateStr}.${extension}`;
    
    const blob = new Blob([data], { type });
    const url = URL.createObjectURL(blob);
    const link = document.createElement("a");
    link.href = url;
    link.setAttribute("download", filename);
    document.body.appendChild(link);
    link.click();
    document.body.removeChild(link);
    URL.revokeObjectURL(url);
  };

  return (
    <div className="fixed inset-0 z-50 flex items-center justify-center p-4">
      {/* Backdrop */}
      <motion.div 
        initial={{ opacity: 0 }}
        animate={{ opacity: 1 }}
        exit={{ opacity: 0 }}
        transition={{ duration: prefersReduced ? 0 : 0.22, ease: [0.2, 0, 0, 1] }}
        className="fixed inset-0 bg-black/60 backdrop-blur-sm"
        onClick={onClose}
      />
      
      {/* Dialog */}
      <motion.div 
        initial={{ opacity: 0, scale: 0.95, y: 20 }}
        animate={{ opacity: 1, scale: 1, y: 0 }}
        exit={{ opacity: 0, scale: 0.95, y: 20 }}
        transition={{ duration: prefersReduced ? 0 : 0.22, ease: [0.05, 0.7, 0.1, 1] }}
        className="relative w-full max-w-xl rounded-[32px] shadow-2xl overflow-hidden flex flex-col"
        style={{ 
          backgroundColor: "color-mix(in srgb, var(--mec-card) 95%, transparent)",
          border: "1px solid color-mix(in srgb, var(--mec-ink-primary) 10%, transparent)",
          color: "var(--mec-ink-primary)"
        }}
      >
        {/* Header */}
        <div className="flex items-center justify-between p-6 pb-4">
          <div>
            <h2 className="text-[18px] font-semibold leading-tight tracking-tight">Export Data</h2>
            <p className="text-[15px] mt-1" style={{ color: "var(--mec-ink-secondary)" }}>
              Download clinical records for {patientName}
            </p>
          </div>
          <button 
            onClick={onClose}
            className="p-2 rounded-full active:scale-95 transition-transform"
            style={{ 
              backgroundColor: "color-mix(in srgb, var(--mec-ink-primary) 8%, transparent)",
            }}
          >
            <X size={20} />
          </button>
        </div>

        {/* Content */}
        <div className="px-6 py-2 flex flex-col gap-6">
          {/* Format Toggle */}
          <div className="flex gap-2">
            <button
              onClick={() => setFormat("csv")}
              className="flex items-center gap-2 px-4 py-2 rounded-full text-[13px] font-medium active:scale-95 transition-all"
              style={{
                backgroundColor: format === "csv" 
                  ? "color-mix(in srgb, var(--mec-s1) 15%, transparent)"
                  : "transparent",
                color: format === "csv" ? "var(--mec-s1)" : "var(--mec-ink-secondary)",
                border: format === "csv" ? "1px solid var(--mec-s1)" : "1px solid color-mix(in srgb, var(--mec-ink-primary) 12%, transparent)"
              }}
            >
              <Table2 size={16} />
              CSV Data
            </button>
            <button
              onClick={() => setFormat("summary")}
              className="flex items-center gap-2 px-4 py-2 rounded-full text-[13px] font-medium active:scale-95 transition-all"
              style={{
                backgroundColor: format === "summary" 
                  ? "color-mix(in srgb, var(--mec-s1) 15%, transparent)"
                  : "transparent",
                color: format === "summary" ? "var(--mec-s1)" : "var(--mec-ink-secondary)",
                border: format === "summary" ? "1px solid var(--mec-s1)" : "1px solid color-mix(in srgb, var(--mec-ink-primary) 12%, transparent)"
              }}
            >
              <FileText size={16} />
              Clinical Summary
            </button>
          </div>

          {/* Preview Area */}
          <div className="flex flex-col gap-2">
            <span className="text-[13px] font-medium px-1" style={{ color: "var(--mec-ink-secondary)" }}>Preview</span>
            <div 
              className="rounded-2xl p-4 overflow-y-auto max-h-[40vh]"
              style={{ backgroundColor: "var(--mec-elevated)" }}
            >
              <pre className="text-xs whitespace-pre-wrap font-mono leading-relaxed" style={{ color: "var(--mec-ink-primary)" }}>
                {format === "csv" 
                  ? (csvData.split('\n').slice(0, 10).join('\n') + (readings.length > 9 ? '\n...' : '')) 
                  : summaryData}
              </pre>
            </div>
          </div>
        </div>

        {/* Footer */}
        <div className="p-6 pt-4 mt-auto flex justify-end gap-3">
          <button
            onClick={onClose}
            className="px-6 py-2.5 rounded-full text-[15px] font-medium active:scale-95 transition-transform"
            style={{ 
              backgroundColor: "transparent",
              border: "1px solid color-mix(in srgb, var(--mec-ink-primary) 20%, transparent)"
            }}
          >
            Cancel
          </button>
          <button
            onClick={handleDownload}
            className="flex items-center gap-2 px-6 py-2.5 rounded-full text-[15px] font-medium active:scale-95 transition-transform"
            style={{ 
              backgroundColor: "var(--mec-s1)",
              color: "#ffffff"
            }}
          >
            <Download size={18} />
            Download {format === "csv" ? "CSV" : "Report"}
          </button>
        </div>
      </motion.div>
    </div>
  );
}
