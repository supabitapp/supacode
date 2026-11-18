import { ArrowDown01Icon } from "@hugeicons/core-free-icons";
import { HugeiconsIcon } from "@hugeicons/react";
import { Separator } from "@repo/ui/components/ui/separator";
import { type ReactNode, useId } from "react";
import { BrewInstallCommand, DownloadButton, TrackedLink } from "./components";

const navLinkClass =
  "inline-flex min-h-11 items-center px-2 transition-colors hover:text-foreground";

const textLinkClass =
  "inline-flex min-h-11 items-center underline decoration-rule-strong underline-offset-4 transition-colors hover:text-foreground hover:decoration-foreground";

const cellInset = "px-7 md:px-9";

const features = [
  {
    title: "Fully native",
    description:
      "Built on libghostty. No Electron, no web wrappers. Pure macOS performance you can feel in every keystroke.",
    badge: "macOS",
  },
  {
    title: "Bring your own agents",
    description:
      "Run Claude Code, Codex, Opencode — any CLI agent, no translation layer. Your terminal, your rules.",
    badge: "BYOA",
  },
  {
    title: "Worktree isolation",
    description:
      "Every agent gets its own git worktree. No conflicts, no stepping on toes. True parallel development.",
    badge: "Git",
  },
  {
    title: "GitHub native",
    description:
      "Open PRs, review CI checks, resolve conflicts — all without leaving the terminal.",
    badge: "GitHub",
  },
  {
    title: "Source available",
    description: "Read the code, report issues, and contribute on GitHub.",
    badge: "Source",
  },
  {
    title: "50+ agents",
    description:
      "Run dozens of coding agents simultaneously. Each in its own isolated environment, all under one roof.",
    badge: "Scale",
  },
];

const licenseQuestions = [
  {
    question: "What counts toward the free trial?",
    answer:
      "Your first five successful local worktree creations across all repositories on this Mac. Deleting a worktree does not reset the count. Failed creations do not count, and SSH worktree creation stays free.",
  },
  {
    question: "What happens after five creations?",
    answer:
      "Supacode asks for a license before creating another local worktree. Your existing worktrees and terminals remain usable. If you already use Supacode, you get five additional local creations when you first install the licensed version.",
  },
  {
    question: "How do I activate or move my license?",
    answer:
      "For Basic and Standard, we email your license key after checkout. Paste it into Settings → License. Basic allows one active Mac and Standard allows two, both for one person. Team buyers use the license portal to assign seats and email each person their own key for one Mac. Deactivate a Mac in Settings → License to free its place; Team owners can also reassign seats in the portal.",
  },
  {
    question: "Do I have to renew?",
    answer:
      "No. Keep using the versions you own forever. Your purchase includes one year of updates. Basic and Standard can renew for $59 USD per license for another year, with no automatic renewal. Contact support for Team update renewals. Basic and Standard owners can download included versions from the license portal.",
  },
  {
    question: "Can I work offline?",
    answer:
      "Activation needs an internet connection. Every plan can use its saved license offline for versions it owns. Transfers, refunds, and other license changes take effect on a Mac after its next successful license refresh.",
  },
];

type PlanId = "basic" | "standard" | "team";

function Plan({
  plan,
  name,
  price,
  unit,
  primary = false,
  children,
}: {
  plan: PlanId;
  name: string;
  price: number;
  unit: string;
  primary?: boolean;
  children: ReactNode;
}) {
  const tone = primary
    ? "border-primary bg-primary text-primary-foreground hover:border-foreground hover:bg-foreground"
    : "border-rule-strong text-foreground hover:bg-muted";

  return (
    <div className={`flex flex-col gap-8 py-7 md:py-9 ${cellInset}`}>
      <div className="flex flex-col gap-6">
        <h3 className="text-2xl font-semibold tracking-tight">{name}</h3>
        <div className="flex flex-col gap-2">
          <p className="flex flex-wrap items-baseline gap-x-2 gap-y-1">
            <span className="text-price font-semibold tabular-nums">${price}</span>
            <span className="text-sm whitespace-nowrap text-muted-foreground">USD / {unit}</span>
          </p>
          <div className="text-sm leading-relaxed text-pretty text-muted-foreground">
            {children}
          </div>
        </div>
      </div>
      <TrackedLink
        href={`https://license.supacode.sh/buy?plan=${plan}`}
        event={`purchase_${plan}_clicked`}
        className={`mt-auto inline-flex min-h-11 items-center justify-center rounded-md border px-6 text-sm font-medium transition-[background-color,border-color,scale] duration-150 ease-out active:scale-[0.96] motion-reduce:transition-none ${tone}`}
      >
        Buy {name}
      </TrackedLink>
    </div>
  );
}

function PlanBox({
  terms,
  children,
}: {
  terms?: { label: string; items: string[] };
  children: ReactNode;
}) {
  const termsLabelId = useId();

  return (
    <div className="rounded-xl border border-rule bg-background">
      <div className="grid divide-y divide-rule md:grid-cols-2 md:divide-x md:divide-y-0">
        {children}
      </div>
      {terms && (
        <div className="grid gap-y-2 border-t border-rule py-5 text-sm text-pretty md:grid-cols-2">
          <p id={termsLabelId} className={`font-medium ${cellInset}`}>
            {terms.label}
          </p>
          <ul
            aria-labelledby={termsLabelId}
            className={`flex flex-col gap-2 text-muted-foreground ${cellInset}`}
          >
            {terms.items.map((term) => (
              <li key={term}>{term}</li>
            ))}
          </ul>
        </div>
      )}
    </div>
  );
}

export default function Home() {
  return (
    <main>
      <div className="mx-auto flex min-h-screen max-w-[1200px] flex-col px-6 py-10 md:px-8">
        <nav
          className="supacode-reveal mb-20 flex flex-col gap-3 sm:flex-row sm:items-center sm:justify-between md:mb-28"
          style={{ animationDelay: "40ms" }}
        >
          <div className="flex items-center gap-3">
            <img src="/supacode-app-icon.png" alt="" className="size-9" />
            <span className="text-sm font-medium uppercase tracking-[0.3em] text-foreground">
              supacode
            </span>
          </div>
          <div className="-mx-2 flex flex-wrap items-center gap-x-1 text-sm text-muted-foreground sm:justify-end sm:gap-x-2">
            <TrackedLink href="#pricing" event="nav_pricing_clicked" className={navLinkClass}>
              Pricing
            </TrackedLink>
            <TrackedLink
              href="https://license.supacode.sh/login"
              event="nav_license_clicked"
              className={navLinkClass}
            >
              My license
            </TrackedLink>
            <TrackedLink
              href="https://docs.supacode.sh"
              event="nav_docs_clicked"
              className={navLinkClass}
            >
              Docs
            </TrackedLink>
            <TrackedLink
              href="https://github.com/supabitapp/supacode"
              event="nav_github_clicked"
              className={navLinkClass}
            >
              GitHub
            </TrackedLink>
          </div>
        </nav>

        <section className="mb-16 flex flex-col items-center text-center md:mb-24">
          <h1
            className="supacode-reveal max-w-4xl text-4xl font-semibold tracking-tight md:text-6xl lg:text-7xl"
            style={{ animationDelay: "120ms" }}
          >
            The command center for coding agents.
          </h1>
          <p
            className="supacode-reveal mt-6 max-w-xl text-base text-muted-foreground md:text-lg"
            style={{ animationDelay: "200ms" }}
          >
            Run 50+ coding agents in parallel. Blazing fast, source available, native macOS app
            built on libghostty.
          </p>
          <div
            className="supacode-reveal mt-10 flex flex-col items-center gap-2"
            style={{ animationDelay: "280ms" }}
          >
            <DownloadButton />
            <span className="text-sm text-muted-foreground">or</span>
            <BrewInstallCommand />
            <span className="mt-1 text-xs text-muted-foreground">Requires macOS 26 Tahoe</span>
          </div>
        </section>

        <section className="supacode-reveal mb-24 md:mb-32" style={{ animationDelay: "360ms" }}>
          <div className="hero-glow relative overflow-hidden rounded-xl border border-border/50">
            <img
              src="/screenshot.png"
              alt="Supacode running multiple coding agents in parallel"
              width={3600}
              height={2210}
              className="w-full"
            />
          </div>
          <p className="mt-4 text-center text-sm text-muted-foreground">
            Actual screenshot of using supacode to develop supacode
          </p>
        </section>

        <Separator className="supacode-reveal mb-24 md:mb-32" style={{ animationDelay: "420ms" }} />

        <section className="mb-24 md:mb-32">
          <h2
            className="supacode-reveal mb-12 text-center text-sm font-medium uppercase tracking-[0.3em] text-muted-foreground md:mb-16"
            style={{ animationDelay: "480ms" }}
          >
            Built different
          </h2>
          <div className="grid gap-px overflow-hidden rounded-xl border border-border/50 bg-border/50 md:grid-cols-2 lg:grid-cols-3">
            {features.map((feature, index) => (
              <div
                key={feature.title}
                className="supacode-reveal flex flex-col gap-3 bg-background p-8"
                style={{ animationDelay: `${540 + index * 60}ms` }}
              >
                <span className="w-fit rounded-full border border-border/70 px-2.5 py-0.5 text-[11px] font-medium uppercase tracking-[0.2em] text-muted-foreground">
                  {feature.badge}
                </span>
                <h3 className="text-lg font-semibold tracking-tight">{feature.title}</h3>
                <p className="text-sm leading-relaxed text-muted-foreground">
                  {feature.description}
                </p>
              </div>
            ))}
          </div>
        </section>

        <section
          id="pricing"
          aria-labelledby="pricing-heading"
          className="mx-auto mb-24 w-full max-w-4xl scroll-mt-10 md:mb-32"
        >
          <div className="mx-auto max-w-2xl text-center">
            <h2
              id="pricing-heading"
              className="text-3xl font-semibold tracking-tight text-balance md:text-4xl"
            >
              Buy once. Use forever.
            </h2>
            <p className="mt-4 text-pretty text-muted-foreground">
              A lifetime license with unlimited local worktree creations and one year of updates. No
              subscription, no automatic renewal.
            </p>
          </div>

          <div className="mt-12 flex flex-col gap-6">
            <PlanBox
              terms={{
                label: "Basic and Standard",
                items: [
                  "Move between Macs by deactivating a previous Mac",
                  "Optional $59 renewal for the whole license",
                ],
              }}
            >
              <Plan plan="basic" name="Basic" price={99} unit="license">
                <p>One person on one Mac.</p>
              </Plan>
              <Plan plan="standard" name="Standard" price={129} unit="license" primary>
                <p>One person on two Macs.</p>
                <p>
                  <s className="tabular-nums">$198</s>{" "}
                  <span className="font-medium text-foreground">Save 35%</span> compared with two
                  Basic licenses.
                </p>
              </Plan>
            </PlanBox>

            <PlanBox>
              <Plan plan="team" name="Team" price={79} unit="seat">
                <p>One Mac per seat, minimum 3 seats.</p>
              </Plan>
              <ul
                className={`flex flex-col gap-2 py-7 text-sm text-pretty text-muted-foreground md:py-9 ${cellInset}`}
              >
                <li>Team portal for seat assignment and reassignment</li>
                <li>Each seat gets its own license key</li>
                <li>Optional renewal through support</li>
              </ul>
            </PlanBox>
          </div>

          <div className="mt-20 grid gap-8 md:grid-cols-[minmax(0,1fr)_minmax(0,2fr)] md:gap-x-12">
            <div className="flex flex-col items-start gap-1 text-sm text-muted-foreground">
              <h3 className="mb-2 text-xl font-semibold tracking-tight text-foreground">
                Licensing questions
              </h3>
              <p className="flex flex-wrap items-center gap-x-2">
                Need help?
                <a href="mailto:license@supacode.sh" className={textLinkClass}>
                  license@supacode.sh
                </a>
              </p>
              <TrackedLink
                href="https://license.supacode.sh/login"
                event="pricing_license_clicked"
                className={textLinkClass}
              >
                Manage an existing license
              </TrackedLink>
            </div>
            <div className="border-t border-rule">
              {licenseQuestions.map(({ question, answer }) => (
                <details key={question} className="group border-b border-rule">
                  <summary className="flex min-h-11 cursor-pointer list-none items-center justify-between gap-6 py-4 font-medium text-pretty [&::-webkit-details-marker]:hidden">
                    {question}
                    <HugeiconsIcon
                      icon={ArrowDown01Icon}
                      strokeWidth={2}
                      className="size-4 shrink-0 text-muted-foreground transition-[rotate,color] duration-150 ease-out group-hover:text-foreground group-open:rotate-180 motion-reduce:transition-none"
                    />
                  </summary>
                  <p className="max-w-[65ch] pb-6 text-sm leading-relaxed text-pretty text-muted-foreground">
                    {answer}
                  </p>
                </details>
              ))}
            </div>
          </div>
        </section>

        <Separator className="supacode-reveal" />

        <footer className="supacode-reveal flex flex-col items-center gap-4 py-10 text-sm text-muted-foreground md:flex-row md:justify-between">
          <div className="flex items-center gap-3">
            <img src="/supacode-app-icon.png" alt="" className="size-5" />
            <span className="font-medium text-foreground">Supacode</span>
          </div>
          <div className="-mx-2 flex flex-wrap justify-center gap-x-2">
            <a href="https://license.supacode.sh/terms" className={navLinkClass}>
              Terms
            </a>
            <a href="https://license.supacode.sh/refunds" className={navLinkClass}>
              Refunds
            </a>
            <a href="https://license.supacode.sh/privacy" className={navLinkClass}>
              Privacy
            </a>
            <TrackedLink
              href="https://github.com/supabitapp/supacode"
              event="footer_github_clicked"
              className={navLinkClass}
            >
              GitHub
            </TrackedLink>
            <TrackedLink
              href="https://github.com/supabitapp/supacode/releases"
              event="footer_releases_clicked"
              className={navLinkClass}
            >
              Releases
            </TrackedLink>
            <TrackedLink
              href="https://docs.supacode.sh"
              event="footer_docs_clicked"
              className={navLinkClass}
            >
              Docs
            </TrackedLink>
            <TrackedLink
              href="https://x.com/khoiracle"
              event="footer_twitter_clicked"
              className={navLinkClass}
            >
              @khoiracle
            </TrackedLink>
          </div>
        </footer>
      </div>
    </main>
  );
}
