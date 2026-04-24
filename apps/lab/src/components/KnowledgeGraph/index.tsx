// Copyright (c) 2026 Brad Duhon. All Rights Reserved.
// Confidential and Proprietary.
// Unauthorized copying of this file is strictly prohibited.

import { useState, useEffect, useRef, useCallback } from 'preact/hooks';
import {
  forceSimulation,
  forceLink,
  forceManyBody,
  forceCenter,
  forceCollide,
  type Simulation,
} from 'd3-force';
import type { GraphData, GraphNode, GraphEdge, NodePosition } from './types';
import EnvelopeNode from './EnvelopeNode';
// import TagNode from './TagNode'; // TAG RESTORE: uncomment to re-enable tag nodes
import PreviewCard from './PreviewCard';

const HOVER_DELAY_MS = 600;
const MAX_DEPTH      = 3;
const MAX_NODES      = 16;

// ---------------------------------------------------------------------------
// Stable hash — deterministic variation per node/edge without random drift
// ---------------------------------------------------------------------------
function stableHash(str: string): number {
  let h = 0;
  for (let i = 0; i < str.length; i++) {
    h = Math.imul(31, h) + str.charCodeAt(i) | 0;
  }
  return Math.abs(h);
}

// ---------------------------------------------------------------------------
// BFS with relevance scoring — returns the top MAX_NODES most relevant nodes
// within MAX_DEPTH hops of the center.
//
// Scoring:
//   hop 1: score = edge relevance (tag) or normalized weight (related) — max 1.0
//   hop 2: score = parent_score * 0.65
//   hop 3: score = parent_score * 0.65^2
// Center is always included regardless of score.
// ---------------------------------------------------------------------------
function resolveId(n: string | GraphNode): string {
  return typeof n === 'string' ? n : n.id;
}

function getTopNeighborhood(
  centerId: string,
  nodes: GraphNode[],
  edges: GraphEdge[]
) {
  // Build adjacency: id -> [{neighborId, edge}]
  const adj = new Map<string, Array<{ id: string; edge: GraphEdge }>>();
  nodes.forEach((n) => adj.set(n.id, []));
  edges.forEach((e) => {
    const s = resolveId(e.source);
    const t = resolveId(e.target);
    adj.get(s)?.push({ id: t, edge: e });
    adj.get(t)?.push({ id: s, edge: e });
  });

  // Compute max semantic weight for normalization
  const maxWeight = edges.reduce((m, e) => Math.max(m, e.weight ?? 1), 1);

  const scores = new Map<string, number>();
  scores.set(centerId, Infinity);

  // BFS queue: [nodeId, depth, inheritedScore]
  const queue: Array<[string, number, number]> = [[centerId, 0, 1]];

  while (queue.length > 0) {
    const [id, depth, parentScore] = queue.shift()!;
    if (depth >= MAX_DEPTH) continue;

    (adj.get(id) ?? []).forEach(({ id: nid, edge }) => {
      if (nid === centerId) return;

      // Edge strength: relevance for tag edges, normalized weight for related
      const strength =
        edge.kind === 'tag'
          ? (edge.relevance ?? 0.5)
          : (edge.weight ?? 1) / maxWeight;

      const score = parentScore * 0.65 * Math.max(strength, 0.3);
      const existing = scores.get(nid);

      if (existing === undefined || score > existing) {
        scores.set(nid, score);
        queue.push([nid, depth + 1, score]);
      }
    });
  }

  // Take top MAX_NODES by score (center always in)
  const ranked = [...scores.entries()]
    .filter(([id]) => id !== centerId)
    .sort((a, b) => b[1] - a[1])
    .slice(0, MAX_NODES - 1)
    .map(([id]) => id);

  const selectedIds = new Set([centerId, ...ranked]);

  return {
    visibleNodes: nodes.filter((n) => selectedIds.has(n.id)),
    visibleEdges: edges.filter((e) => {
      const s = resolveId(e.source);
      const t = resolveId(e.target);
      return selectedIds.has(s) && selectedIds.has(t);
    }),
    scores,
  };
}

// ---------------------------------------------------------------------------
// Edge clipping — find the point on a node's boundary toward another point
// so lines terminate at the node surface, not its center.
// ---------------------------------------------------------------------------
const ARTICLE_CENTER_W   = 180;
const ARTICLE_CENTER_H   = 80;
const ARTICLE_NEIGHBOR_W = 120;
const ARTICLE_NEIGHBOR_H = 38;
// const ARTICLE_NEIGHBOR_R = 18; // TAG RESTORE: was circle radius for neighbor nodes

// TAG RESTORE: uncomment tag geometry helpers
// const TAG_BASE_H    = 22;
// const TAG_CHAR_W    = 6.5;
// const TAG_BASE_FONT = 10;
// const TAG_PAD_X     = 10;
// function getTagWidth(label: string, relevance: number): number {
//   const scale = 1 + relevance * 0.65;
//   const fontSize = Math.round(TAG_BASE_FONT * scale);
//   const padX = Math.round(TAG_PAD_X * scale);
//   return Math.max(label.length * (fontSize * TAG_CHAR_W / TAG_BASE_FONT) + padX * 2, 36);
// }
// function getTagHeight(relevance: number): number {
//   const scale = 1 + relevance * 0.65;
//   return Math.round(TAG_BASE_H * scale);
// }

function clampToRect(cx: number, cy: number, hw: number, hh: number, tx: number, ty: number): [number, number] {
  const dx = tx - cx;
  const dy = ty - cy;
  if (dx === 0 && dy === 0) return [cx, cy];
  const scaleX = dx !== 0 ? hw / Math.abs(dx) : Infinity;
  const scaleY = dy !== 0 ? hh / Math.abs(dy) : Infinity;
  const s = Math.min(scaleX, scaleY);
  return [cx + dx * s, cy + dy * s];
}

function clampToCircle(cx: number, cy: number, r: number, tx: number, ty: number): [number, number] {
  const dx = tx - cx;
  const dy = ty - cy;
  const len = Math.sqrt(dx * dx + dy * dy);
  if (len === 0) return [cx, cy];
  return [cx + (dx / len) * r, cy + (dy / len) * r];
}

function getEdgeEndpoint(
  fromPos: NodePosition,
  toPos: NodePosition,
  toNode: GraphNode,
  toIsCenter: boolean,
  // toRelevance: number  // TAG RESTORE: re-add for tag pill sizing
): [number, number] {
  if (toIsCenter) {
    return clampToRect(toPos.x, toPos.y, ARTICLE_CENTER_W / 2, ARTICLE_CENTER_H / 2, fromPos.x, fromPos.y);
  }
  return clampToRect(toPos.x, toPos.y, ARTICLE_NEIGHBOR_W / 2, ARTICLE_NEIGHBOR_H / 2, fromPos.x, fromPos.y);
  // TAG RESTORE: add back tag pill clipping:
  // if (toNode.type === 'article') {
  //   if (toIsCenter) return clampToRect(...CENTER);
  //   return clampToCircle(toPos.x, toPos.y, ARTICLE_NEIGHBOR_R, fromPos.x, fromPos.y);
  // }
  // const w = getTagWidth(toNode.label, toRelevance);
  // const h = getTagHeight(toRelevance);
  // return clampToRect(toPos.x, toPos.y, w / 2, h / 2, fromPos.x, fromPos.y);
}

// ---------------------------------------------------------------------------
// Main component
// ---------------------------------------------------------------------------
interface Props {
  initialCenterId: string;
}

export default function KnowledgeGraph({ initialCenterId }: Props) {
  const [graphData, setGraphData] = useState<GraphData | null>(null);
  const [centerId, setCenterId] = useState<string>(initialCenterId);
  const [positions, setPositions] = useState<Record<string, NodePosition>>({});
  const [previewNode, setPreviewNode] = useState<GraphNode | null>(null);
  const [previewPos, setPreviewPos]   = useState<NodePosition>({ x: 0, y: 0 });
  const [dimensions, setDimensions] = useState({ w: 800, h: 520 });

  const containerRef = useRef<HTMLDivElement>(null);
  const simulationRef = useRef<Simulation<GraphNode, GraphEdge> | null>(null);
  const hoverTimer = useRef<ReturnType<typeof setTimeout> | null>(null);
  const rafRef = useRef<number>(0);

  useEffect(() => {
    fetch('/graph.json').then((r) => r.json()).then(setGraphData).catch(console.error);
  }, []);

  // If the baked-in initialCenterId (from index.html build time) doesn't exist
  // in the fetched graph data, fall back to the graph's own initialCenter.
  // This happens when graph.json was browser-cached from a previous build.
  useEffect(() => {
    if (!graphData) return;
    if (!graphData.nodes.some((n) => n.id === centerId) && graphData.initialCenter) {
      setCenterId(graphData.initialCenter);
    }
  }, [graphData]);

  useEffect(() => {
    if (!containerRef.current) return;
    const ro = new ResizeObserver(([entry]) => {
      const { width, height } = entry.contentRect;
      setDimensions({ w: width, h: Math.max(height, 400) });
    });
    ro.observe(containerRef.current);
    return () => ro.disconnect();
  }, []);

  useEffect(() => {
    if (!graphData) return;

    const { visibleNodes, visibleEdges } = getTopNeighborhood(centerId, graphData.nodes, graphData.edges);
    const { w, h } = dimensions;

    visibleNodes.forEach((n) => {
      if (positions[n.id]) {
        n.x = positions[n.id].x;
        n.y = positions[n.id].y;
      } else {
        const angle = stableHash(n.id) % 628 / 100; // stable initial angle
        const radius = 80 + (stableHash(n.id + 'r') % 60);
        n.x = w / 2 + Math.cos(angle) * radius;
        n.y = h / 2 + Math.sin(angle) * radius;
      }
      n.fx = n.id === centerId ? w / 2 : null;
      n.fy = n.id === centerId ? h / 2 : null;
    });

    if (simulationRef.current) simulationRef.current.stop();

    // Scale forces dynamically: fewer nodes -> stronger repulsion + longer links
    // so the graph fills available canvas space naturally.
    const n = visibleNodes.length;
    const baseCharge    = -Math.max(220, Math.min(600, 2000 / n));
    const baseLinkDist  = 90 + Math.min(160, 700 / n);

    const sim = forceSimulation<GraphNode>(visibleNodes)
      .force(
        'link',
        forceLink<GraphNode, GraphEdge>(visibleEdges)
          .id((d) => d.id)
          .distance((e) => {
            const key = resolveId(e.source) + resolveId(e.target);
            const variation = (stableHash(key) % 70) - 35;
            const base = e.kind === 'related' ? baseLinkDist * 1.5 : baseLinkDist;
            return base + variation;
          })
          .strength(0.45)
      )
      .force(
        'charge',
        forceManyBody<GraphNode>().strength((d) => {
          const variation = stableHash(d.id + 'c') % 120 - 60;
          return baseCharge + variation;
        })
      )
      .force('center', forceCenter(w / 2, h / 2).strength(0.03))
      .force(
        'collide',
        // TAG RESTORE: forceCollide<GraphNode>().radius((d) => (d.type === 'article' ? 60 : 36))
        forceCollide<GraphNode>().radius((d) => (d.id === centerId ? 95 : 65))
      )
      .alpha(0.9)
      .alphaDecay(0.016);

    sim.on('tick', () => {
      cancelAnimationFrame(rafRef.current);
      rafRef.current = requestAnimationFrame(() => {
        const next: Record<string, NodePosition> = {};
        visibleNodes.forEach((n) => { next[n.id] = { x: n.x ?? w / 2, y: n.y ?? h / 2 }; });
        setPositions(next);
      });
    });

    simulationRef.current = sim;
    return () => { sim.stop(); cancelAnimationFrame(rafRef.current); };
  }, [graphData, centerId, dimensions]);

  const clearHoverTimer = useCallback(() => {
    if (hoverTimer.current) { clearTimeout(hoverTimer.current); hoverTimer.current = null; }
  }, []);

  const handleNodeMouseEnter = useCallback((nodeId: string) => {
    if (nodeId === centerId) return;
    clearHoverTimer();
    hoverTimer.current = setTimeout(() => {
      setCenterId(nodeId);
      setPreviewNode(null);
    }, HOVER_DELAY_MS);
  }, [centerId, clearHoverTimer]);

  const handleNodeClick = useCallback((node: GraphNode, e: Event) => {
    e.stopPropagation();
    clearHoverTimer();
    const pos = positions[node.id];
    if (pos) setPreviewPos(pos);
    setPreviewNode((prev) => (prev?.id === node.id ? null : node));
  }, [clearHoverTimer, positions]);

  // TAG RESTORE: uncomment getTagRelevance for tag node sizing
  // const getTagRelevance = useCallback((tagNodeId: string): number => {
  //   if (!graphData) return 0;
  //   const center = graphData.nodes.find((n) => n.id === centerId);
  //   if (!center || center.type !== 'article') return 0;
  //   const edge = graphData.edges.find(
  //     (e) => resolveId(e.source) === centerId && resolveId(e.target) === tagNodeId && e.kind === 'tag'
  //   );
  //   return edge?.relevance ?? 0;
  // }, [graphData, centerId]);

  if (!graphData) {
    return (
      <div style={{ position: 'absolute', inset: 0, display: 'flex', alignItems: 'center', justifyContent: 'center' }}>
        <p style={{ fontFamily: 'monospace', fontSize: '13px', color: '#92400E' }}>Loading graph...</p>
      </div>
    );
  }

  const { visibleNodes, visibleEdges } = getTopNeighborhood(centerId, graphData.nodes, graphData.edges);
  const { w, h } = dimensions;

  return (
    <div ref={containerRef} style={{ position: 'absolute', inset: 0 }}>
      <svg
        viewBox={`0 0 ${w} ${h}`}
        style={{ display: 'block', width: '100%', height: '100%' }}
        onClick={() => setPreviewNode(null)}
      >
        {/* Edges — clipped to node boundaries */}
        {visibleEdges.map((edge, i) => {
          const sid = resolveId(edge.source);
          const tid = resolveId(edge.target);
          const sp = positions[sid];
          const tp = positions[tid];
          if (!sp || !tp) return null;

          const sNode = visibleNodes.find((n) => n.id === sid);
          const tNode = visibleNodes.find((n) => n.id === tid);
          if (!sNode || !tNode) return null;

          // TAG RESTORE: pass sRel/tRel from getTagRelevance() as 5th arg to getEdgeEndpoint
          const [x1, y1] = getEdgeEndpoint(tp, sp, sNode, sid === centerId);
          const [x2, y2] = getEdgeEndpoint(sp, tp, tNode, tid === centerId);

          // Weight range: 1 (single rank-2 match) to 14 (all 3 top tags match).
          // Map to stroke-width 0.8-3.5px so stronger correlations visually pop.
          const strokeWidth = Math.min(0.8 + (edge.weight ?? 1) * 0.22, 3.5);
          return (
            <line
              key={`e-${i}`}
              x1={x1} y1={y1} x2={x2} y2={y2}
              stroke="#D97706"
              stroke-width={strokeWidth}
              opacity={0.3 + Math.min((edge.weight ?? 1) / 14, 1) * 0.45}
            />
          );
        })}

        {/* Nodes */}
        {visibleNodes.map((node) => {
          const pos = positions[node.id];
          if (!pos) return null;
          const isCenter = node.id === centerId;

          if (node.type === 'article') {
            return (
              <EnvelopeNode
                key={node.id}
                node={node}
                isCenter={isCenter}
                x={pos.x}
                y={pos.y}
                onMouseEnter={() => handleNodeMouseEnter(node.id)}
                onMouseLeave={clearHoverTimer}
                onClick={(e) => handleNodeClick(node, e as Event)}
              />
            );
          }

          // TAG RESTORE: uncomment TagNode rendering
          // const relevance = getTagRelevance(node.id);
          // return (
          //   <TagNode
          //     key={node.id}
          //     node={node}
          //     isCenter={isCenter}
          //     relevance={relevance}
          //     x={pos.x}
          //     y={pos.y}
          //     onMouseEnter={() => handleNodeMouseEnter(node.id)}
          //     onMouseLeave={clearHoverTimer}
          //     onClick={(e) => handleNodeClick(node, e as Event)}
          //   />
          // );
          return null;
        })}
      </svg>

      {previewNode && (
        <PreviewCard
          node={previewNode}
          allNodes={graphData.nodes}
          nodeX={previewPos.x}
          nodeY={previewPos.y}
          canvasW={w}
          canvasH={h}
          onClose={() => setPreviewNode(null)}
        />
      )}
    </div>
  );
}
