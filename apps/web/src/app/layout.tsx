import type { Metadata } from "next";
import { Inter } from "next/font/google";
import "./globals.css";

// Inter, per docs/design.md §3.4. No display or serif face anywhere in this
// system — including the hero risk figure.
const inter = Inter({
  variable: "--font-inter",
  subsets: ["latin"],
});

export const metadata: Metadata = {
  title: "MEC-AI Dashboard",
  description:
    "Cardiovascular risk monitoring for MEC-AI wearable cuffs. Screening indicators, not diagnoses.",
  icons: {
    icon: "/mec-ai-logo.png",
  },
};

export default function RootLayout({ children }: LayoutProps<"/">) {
  return (
    // Dark is the default, not a preference: the Moderate amber token only
    // clears contrast on a dark surface (1.79 light vs 9.49 dark).
    // See docs/design.md §2.
    <html lang="en" className={`${inter.variable} h-full antialiased`}>
      <body className="min-h-full flex flex-col">{children}</body>
    </html>
  );
}
