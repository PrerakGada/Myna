import type { Metadata, Viewport } from "next";
import { Fraunces, Newsreader, JetBrains_Mono } from "next/font/google";
import "./globals.css";

const fraunces = Fraunces({
  subsets: ["latin"],
  variable: "--font-fraunces",
  display: "swap",
  axes: ["SOFT", "opsz"],
  style: ["normal", "italic"],
});

const newsreader = Newsreader({
  subsets: ["latin"],
  variable: "--font-newsreader",
  display: "swap",
  style: ["normal", "italic"],
});

const jetbrains = JetBrains_Mono({
  subsets: ["latin"],
  variable: "--font-jetbrains",
  display: "swap",
  weight: ["400", "500"],
});

export const metadata: Metadata = {
  metadataBase: new URL("https://myna.dev"),
  title: "Myna — A quiet voice for your Mac",
  description:
    "A free, open-source native macOS menu-bar app that reads selections, articles, and finished Claude Code sessions aloud. Real audio engine, signed + notarised, auto-updating, runs entirely on Apple Silicon. No cloud, no cost, no noise.",
  openGraph: {
    title: "Myna — A quiet voice for your Mac",
    description:
      "Native macOS menu-bar TTS. Reads selections, articles, and Claude Code output aloud. 100% local, free forever, MIT-licensed.",
    type: "website",
    url: "/",
    siteName: "Myna",
  },
  twitter: {
    card: "summary_large_image",
    title: "Myna — A quiet voice for your Mac",
    description:
      "Native macOS menu-bar TTS. Reads selections, articles, and Claude Code output aloud. 100% local, free forever, MIT-licensed.",
  },
  authors: [{ name: "Prerak Gada", url: "https://github.com/PrerakGada" }],
  creator: "Prerak Gada",
  icons: {
    icon: "/favicon.svg",
  },
};

export const viewport: Viewport = {
  themeColor: "#F5EFE2",
  width: "device-width",
  initialScale: 1,
  maximumScale: 5,
};

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html
      lang="en"
      className={`${fraunces.variable} ${newsreader.variable} ${jetbrains.variable}`}
    >
      <body className="bg-paper text-ink antialiased">
        <div className="grain-overlay" aria-hidden="true" />
        {children}
      </body>
    </html>
  );
}
