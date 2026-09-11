/** @type {import('next').NextConfig} */
const RELEASES = "https://github.com/PrerakGada/Myna/releases";

const nextConfig = {
  reactStrictMode: true,
  poweredByHeader: false,
  compress: true,
  async redirects() {
    return [
      // The disk image from the newest release. release.yml uploads a copy
      // named Myna.dmg to every release, so this link never goes stale.
      { source: "/download", destination: `${RELEASES}/latest/download/Myna.dmg`, permanent: false },
      { source: "/download/mac", destination: `${RELEASES}/latest/download/Myna.dmg`, permanent: false },
      { source: "/releases", destination: RELEASES, permanent: false },
    ];
  },
};

export default nextConfig;
