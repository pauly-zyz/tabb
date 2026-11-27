"use client";

import Link from "next/link";
import { usePathname } from "next/navigation";
import { ConnectButton } from "./ConnectButton";
import { NetworkSwitcher } from "./NetworkSwitcher";

const LINKS = [
  { href: "/lend/", label: "Lend", icon: "◎" },
  { href: "/agents/", label: "Open a Tab", icon: "＋" },
  { href: "/tabs/", label: "My Tabs", icon: "▤" },
  { href: "/risk/", label: "Risk", icon: "⚑" },
  { href: "/yield/", label: "Yield", icon: "✦" },
];

export function Nav() {
  const path = usePathname();
  const active = (href: string) => path === href || path === href.slice(0, -1);
  return (
    <>
      <header className="sticky top-0 z-30 border-b border-ink-800 bg-ink-950/85 backdrop-blur">
        <div className="mx-auto flex h-14 max-w-5xl items-center justify-between gap-3 px-4">
          <Link href="/" className="flex items-center gap-2 font-semibold">
            <span className="grid h-7 w-7 place-items-center rounded-lg bg-tab-400 text-sm font-black text-ink-950">t</span>
            <span className="text-lg tracking-tight">tabb</span>
          </Link>
          <nav className="hidden gap-1 md:flex">
            {LINKS.map((l) => (
              <Link
                key={l.href}
                href={l.href}
                className={`rounded-lg px-3 py-1.5 text-sm ${active(l.href) ? "bg-ink-800 text-white" : "text-zinc-400 hover:text-white"}`}
              >
                {l.label}
              </Link>
            ))}
          </nav>
          <div className="flex items-center gap-2">
            <NetworkSwitcher />
            <ConnectButton />
          </div>
        </div>
      </header>
      <nav className="fixed inset-x-0 bottom-0 z-30 border-t border-ink-800 bg-ink-950/95 backdrop-blur md:hidden">
        <div className="mx-auto grid max-w-lg grid-cols-5">
          {LINKS.map((l) => (
            <Link
              key={l.href}
              href={l.href}
              className={`flex flex-col items-center gap-0.5 py-2 text-[11px] ${active(l.href) ? "text-tab-400" : "text-zinc-500"}`}
            >
              <span className="text-base leading-none">{l.icon}</span>
              {l.label}
            </Link>
          ))}
        </div>
      </nav>
    </>
  );
}
