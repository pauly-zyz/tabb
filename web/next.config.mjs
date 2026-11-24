/** @type {import('next').NextConfig} */
const nextConfig = {
  output: "export", // fully static dApp (no server needed)
  images: { unoptimized: true },
  trailingSlash: true,
  reactStrictMode: true,
  experimental: { externalDir: true }, // allow importing ../config/addresses.ts
  webpack: (config) => {
    // optional deps pulled by wallet SDKs that are not needed in the browser bundle
    config.externals.push("pino-pretty", "lokijs", "encoding");
    return config;
  },
};
export default nextConfig;
