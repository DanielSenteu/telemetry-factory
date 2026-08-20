import type { Metadata } from "next";
import { Space_Grotesk, IBM_Plex_Mono, Geist } from "next/font/google";
import "./globals.css";

// Brand type system (CONVENTIONS: numbers are always mono):
//   display — Space Grotesk: headings, the wordmark
//   body    — Geist: everything readable
//   mono    — IBM Plex Mono: every number, timestamp and telemetry fragment
const display = Space_Grotesk({ subsets: ["latin"], variable: "--font-display" });
const body = Geist({ subsets: ["latin"], variable: "--font-body" });
const mono = IBM_Plex_Mono({ subsets: ["latin"], weight: ["400", "500", "600"], variable: "--font-mono" });

export const metadata: Metadata = {
  title: "Industrial-Sync",
  description:
    "Industrial-Sync wires into your injection moulding machines and shows you — shot by shot — what is running, what is in stock, and what to make next.",
};

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="en">
      <body className={`${display.variable} ${body.variable} ${mono.variable} font-body antialiased`}>
        {children}
      </body>
    </html>
  );
}
