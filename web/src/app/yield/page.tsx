"use client";

import { Card, Notice, Row, SectionTitle } from "@/components/ui";

export default function YieldPage() {
  return (
    <div className="space-y-5">
      <SectionTitle
        title="Yield Tab"
        subtitle="Phase 2 — self-repaying, overcollateralized credit against yield-bearing assets. Coming soon."
      />
      <Notice>
        Phase 2 is designed (docs/DESIGN.md §9) and will ship after agent credit. The pool already supports a second
        credit line, so yield tabs plug in without touching Phase 1.
      </Notice>
      <div className="grid gap-4 md:grid-cols-2">
        <Card>
          <h2 className="font-semibold">How it will work</h2>
          <ol className="mt-2 list-decimal space-y-1 pl-5 text-sm text-zinc-400">
            <li>Deposit a yield-bearing asset as collateral.</li>
            <li>Borrow USDG up to the max LTV.</li>
            <li>Keepers harvest the yield: interest first, then principal.</li>
            <li>Once repaid, extra yield is credited to you; withdraw your collateral.</li>
          </ol>
        </Card>
        <Card>
          <h2 className="font-semibold">Initial risk parameters</h2>
          <Row k="USDG vault shares (ERC-4626)" v="LTV 80% · LT 85% · bonus 5%" />
          <Row k="Stock-dividend YT (Clipt)" v="LTV 40% · LT 50% · bonus 10%" />
          <Row k="YT maturity haircut" v="10% + 10%/yr, max 50%" />
          <Row k="Market closed (YT)" v="new borrows frozen" />
          <Row k="Close factor" v="50% (100% below HF 0.95)" />
        </Card>
      </div>
    </div>
  );
}
