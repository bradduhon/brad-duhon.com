// Copyright (c) 2026 Brad Duhon. All Rights Reserved.
// Confidential and Proprietary.
// Unauthorized copying of this file is strictly prohibited.

import sharedConfig from '@brad-duhon/shared-ui/tailwind';

/** @type {import('tailwindcss').Config} */
export default {
  ...sharedConfig,
  content: [
    './src/**/*.{astro,html,js,ts,jsx,tsx,md,mdx}',
  ],
  plugins: [
    require('@tailwindcss/typography'),
  ],
};
