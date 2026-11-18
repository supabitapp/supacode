"use client";

import { AppleFinderIcon, Copy01Icon, Tick01Icon } from "@hugeicons/core-free-icons";
import { HugeiconsIcon } from "@hugeicons/react";
import { Button } from "@repo/ui/components/ui/button";
import { posthog } from "posthog-js";
import { type ReactNode, useState } from "react";

export function DownloadButton() {
  return (
    <a
      href="https://supacode.sh/download/latest/supacode.dmg"
      onClick={() => posthog.capture("download_clicked")}
    >
      <Button size="lg" className="gap-2.5 px-6 py-3 text-base">
        <HugeiconsIcon icon={AppleFinderIcon} className="size-5" strokeWidth={2} />
        Download for macOS
      </Button>
    </a>
  );
}

export function BrewInstallCommand() {
  const command = "brew install supacode";
  const [copied, setCopied] = useState(false);

  function copy() {
    navigator.clipboard.writeText(command);
    posthog.capture("brew_install_copied");
    setCopied(true);
    setTimeout(() => setCopied(false), 2000);
  }

  return (
    <button
      type="button"
      onClick={copy}
      className="flex w-fit items-center gap-2.5 rounded-md border border-border/70 px-4 py-2.5 font-mono text-base text-muted-foreground transition-colors hover:text-foreground"
    >
      <span>$ {command}</span>
      <HugeiconsIcon
        icon={copied ? Tick01Icon : Copy01Icon}
        className="size-4 shrink-0"
        strokeWidth={2}
      />
    </button>
  );
}

export function TrackedLink({
  href,
  event,
  children,
  className,
}: {
  href: string;
  event: string;
  children: ReactNode;
  className?: string;
}) {
  return (
    <a href={href} className={className} onClick={() => posthog.capture(event, { href })}>
      {children}
    </a>
  );
}
