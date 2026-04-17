// Copyright (c) 2026 Brad Duhon. All Rights Reserved.
// Confidential and Proprietary.
// Unauthorized copying of this file is strictly prohibited.

import rss from '@astrojs/rss';
import { getCollection } from 'astro:content';
import type { APIContext } from 'astro';

export async function GET(context: APIContext) {
  const entries = await getCollection('entries', ({ data }) => !data.draft);
  const sorted = entries.sort((a, b) => b.data.date.valueOf() - a.data.date.valueOf());

  return rss({
    title: 'Brad Duhon - Lab',
    description: 'Security research, cloud experiments, homelab notes, and TILs.',
    site: context.site!,
    items: sorted.map((entry) => ({
      title:       entry.data.title,
      description: entry.data.description,
      pubDate:     entry.data.date,
      link:        `/${entry.slug}/`,
    })),
  });
}
