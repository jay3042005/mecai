import type { NextConfig } from "next";

const API_BASE = process.env.MECAI_API_URL ?? "http://127.0.0.1:8000";

const nextConfig: NextConfig = {
  output: "standalone",
  // 127.0.0.1 must be explicit — "*" alone is rejected by Next's matcher (single "*" never matches).
  // 192.168.*.* covers the LAN IP shown by the Windows launcher for the Flutter app.
  allowedDevOrigins: ["127.0.0.1", "192.168.*.*", "10.*.*.*"],
  async rewrites() {
    return [
      {
        source: "/api/:path*",
        destination: `${API_BASE}/:path*`,
      },
    ];
  },
};

export default nextConfig;
