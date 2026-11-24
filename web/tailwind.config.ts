import type { Config } from "tailwindcss";

const config: Config = {
  darkMode: "class",
  content: ["./src/**/*.{ts,tsx}"],
  theme: {
    extend: {
      colors: {
        ink: { 950: "#07090c", 900: "#0c1016", 800: "#131922", 700: "#1c2430", 600: "#2a3442" },
        tab: { 400: "#a3e635", 500: "#84cc16", 600: "#65a30d" },
      },
      fontFamily: { sans: ["Inter", "ui-sans-serif", "system-ui", "sans-serif"] },
    },
  },
  plugins: [],
};
export default config;
