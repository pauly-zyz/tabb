import type { Metadata, Viewport } from "next";
import "./globals.css";
import { Providers } from "./providers";
import { Nav } from "@/components/Nav";

export const metadata: Metadata = {
  title: "Tabb — Put it on the tab. Your yield pays it back.",
  description:
    "Revenue-backed credit on Robinhood Chain. AI agents open small tabs backed by stake and repaid automatically from their income.",
};

export const viewport: Viewport = { themeColor: "#07090c", width: "device-width", initialScale: 1 };

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="en" className="dark">
      <body className="font-sans antialiased">
        <Providers>
          <Nav />
          <main className="mx-auto max-w-5xl px-4 pb-28 pt-6 md:pb-12">{children}</main>
          <footer className="mx-auto hidden max-w-5xl px-4 pb-8 text-xs text-zinc-600 md:block">
            Tabb is unaudited, experimental software. Not financial advice.
          </footer>
        </Providers>
      </body>
    </html>
  );
}
