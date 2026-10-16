/** @type {import('next').NextConfig} */
const nextConfig = {
  reactStrictMode: true,
  // packages/engine ships TypeScript source (abis, snapshot, errors), compiled with the app
  transpilePackages: ["@cc/engine"],
  // wagmi/walletconnect pull optional native deps; keep the client build clean.
  webpack: (config, { webpack }) => {
    config.externals.push("pino-pretty", "lokijs", "encoding");
    // rainbowkit -> wagmi coinbase connector -> cdp-sdk references optional
    // x402 payment modules that aren't installed and are never hit here.
    config.plugins.push(
      new webpack.IgnorePlugin({ resourceRegExp: /^@x402\// })
    );
    return config;
  },
};

export default nextConfig;
