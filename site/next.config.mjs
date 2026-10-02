/** @type {import('next').NextConfig} */
const RELEASES = "https://github.com/PrerakGada/Myna/releases";
const DOWNLOAD_URL = "https://api.prerakgada.in/d/myna/mac";

const nextConfig = {
  reactStrictMode: true,
  poweredByHeader: false,
  compress: true,
  async redirects() {
    return [
      // Through the shared download counter (api.prerakgada.in), which 302s to
      // Myna.dmg on the newest release — release.yml uploads a copy named
      // Myna.dmg to every release, so this link never goes stale.
      { source: "/download", destination: DOWNLOAD_URL, permanent: false },
      { source: "/download/mac", destination: DOWNLOAD_URL, permanent: false },
      { source: "/releases", destination: RELEASES, permanent: false },
    ];
  },
};

export default nextConfig;
