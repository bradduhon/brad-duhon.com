// Copyright (c) 2026 Brad Duhon. All Rights Reserved.
// Confidential and Proprietary.
// Unauthorized copying of this file is strictly prohibited.

export interface ArticleNode {
  id: string;
  type: 'article';
  label: string;
  date: string;
  description: string;
  tags: string[];
  slug: string;
  // D3 simulation appends these
  x?: number;
  y?: number;
  vx?: number;
  vy?: number;
  fx?: number | null;
  fy?: number | null;
}

export interface TagNode {
  id: string;
  type: 'tag';
  label: string;
  x?: number;
  y?: number;
  vx?: number;
  vy?: number;
  fx?: number | null;
  fy?: number | null;
}

export type GraphNode = ArticleNode | TagNode;

export interface GraphEdge {
  source: string | GraphNode;
  target: string | GraphNode;
  kind: 'tag' | 'related';
  weight?: number;      // semantic edges: shared tag count
  relevance?: number;   // tag edges: 0-1 content relevance to the source article
}

export interface GraphData {
  nodes: GraphNode[];
  edges: GraphEdge[];
  initialCenter: string | null;
}

export interface NodePosition {
  x: number;
  y: number;
}
