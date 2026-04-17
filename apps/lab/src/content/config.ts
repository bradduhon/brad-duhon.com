// Copyright (c) 2026 Brad Duhon. All Rights Reserved.
// Confidential and Proprietary.
// Unauthorized copying of this file is strictly prohibited.

import { defineCollection, z } from 'astro:content';

const entries = defineCollection({
  type: 'content',
  schema: z.object({
    title:       z.string(),
    date:        z.coerce.date(),
    tags:        z.array(z.string()),
    description: z.string(),
    draft:       z.boolean().default(false),
  }),
});

export const collections = { entries };
