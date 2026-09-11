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

const DESCRIPTION =
  "Select text anywhere and press ⌘⌥⇧S — Myna reads it aloud in a natural voice generated on your Mac. Articles from Chrome, Claude Code replies, a floating player. Free and open source for Apple Silicon.";

export const metadata: Metadata = {
  metadataBase: new URL("https://myna.prerakgada.in"),
  title: "Myna — a quiet voice for your Mac",
  description: DESCRIPTION,
  applicationName: "Myna",
  keywords: ["text to speech", "macOS", "read aloud", "Kokoro", "MLX", "Apple Silicon", "Claude Code", "menu bar app"],
  alternates: { canonical: "/" },
  openGraph: {
    title: "Myna — a quiet voice for your Mac",
    description: DESCRIPTION,
    type: "website",
    url: "/",
    siteName: "Myna",
  },
  twitter: {
    card: "summary_large_image",
    title: "Myna — a quiet voice for your Mac",
    description: DESCRIPTION,
  },
  authors: [{ name: "Prerak Gada", url: "https://github.com/PrerakGada" }],
  creator: "Prerak Gada",
  icons: {
    icon: "/favicon.svg",
    apple: "/apple-touch-icon.png",
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
