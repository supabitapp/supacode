import type { Metadata } from "next";
import { Bricolage_Grotesque } from "next/font/google";
import type { ReactNode } from "react";
import "./globals.css";

const display = Bricolage_Grotesque({
  subsets: ["latin"],
  variable: "--font-supacode",
  display: "swap",
});

export const metadata: Metadata = {
  metadataBase: new URL("https://supacode.sh"),
  title: "Supacode",
  description: "Native terminal coding agents command center. Run 50+ coding agents in parallel.",
  icons: {
    icon: "/supacode-app-icon.png",
  },
  openGraph: {
    title: "Supacode",
    description: "Native terminal coding agents command center. Run 50+ coding agents in parallel.",
    url: "https://supacode.sh",
    siteName: "Supacode",
    images: ["/screenshot.png"],
    type: "website",
  },
  twitter: {
    card: "summary_large_image",
    title: "Supacode",
    description: "Native terminal coding agents command center. Run 50+ coding agents in parallel.",
    images: ["/screenshot.png"],
  },
};

export default function RootLayout({ children }: { children: ReactNode }) {
  return (
    <html lang="en" className={`${display.variable} dark`}>
      <body className="antialiased">{children}</body>
    </html>
  );
}
