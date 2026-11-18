import type { NextConfig } from "next";

const nextConfig: NextConfig = {
  output: "export",
  transpilePackages: ["@repo/ui"],
};

export default nextConfig;
