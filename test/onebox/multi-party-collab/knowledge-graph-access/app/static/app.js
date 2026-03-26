const COLORS = {
  sharedActor: '#3b82f6',
  sharedContract: '#8b5cf6',
  sharedTest: '#0f766e',
  subA: '#16a34a',
  subB: '#f59e0b',
  error: '#dc2626',
  neutral: '#64748b',
};

function getNodeStyle(node) {
  const tags = node.tags || [];
  const isShared = tags.includes('shared');
  const isSubA = tags.includes('company-a');
  const isSubB = tags.includes('company-b');

  let color = COLORS.neutral;
  if (node.type === 'error') {
    color = COLORS.error;
  } else if (isSubA) {
    color = COLORS.subA;
  } else if (isSubB) {
    color = COLORS.subB;
  } else if (isShared && (node.type === 'contract' || node.type === 'field')) {
    color = COLORS.sharedContract;
  } else if (isShared && node.type === 'test') {
    color = COLORS.sharedTest;
  } else if (isShared) {
    color = COLORS.sharedActor;
  }

  return {
    id: node.id,
    label: node.label,
    type: node.type,
    color,
    borderColor: isShared ? '#0f172a' : '#cbd5e1',
    borderWidth: isShared ? 3 : 1.5,
    opacity: isShared ? 1 : 0.96,
  };
}

function createElements(payload) {
  const nodes = payload.nodes.map((node) => ({
    data: getNodeStyle(node),
  }));

  const edges = payload.edges.map((edge, index) => ({
    data: {
      id: `${edge.source}-${edge.target}-${edge.label}-${index}`,
      source: edge.source,
      target: edge.target,
      label: edge.label,
    },
  }));

  return [...nodes, ...edges];
}

function baseGraphOptions(container, elements) {
  return {
    container,
    elements,
    style: [
      {
        selector: 'node',
        style: {
          'background-color': 'data(color)',
          'border-color': 'data(borderColor)',
          'border-width': 'data(borderWidth)',
          'background-opacity': 'data(opacity)',
          label: 'data(label)',
          color: '#0f172a',
          'font-weight': 600,
          'text-wrap': 'wrap',
          'text-max-width': 120,
          'font-size': '11px',
          'text-valign': 'center',
          'text-halign': 'center',
          width: 52,
          height: 52,
          'overlay-opacity': 0,
        },
      },
      {
        selector: 'edge',
        style: {
          width: 2.4,
          'line-color': '#94a3b8',
          'target-arrow-color': '#94a3b8',
          'target-arrow-shape': 'triangle',
          'curve-style': 'bezier',
          'arrow-scale': 1,
          label: 'data(label)',
          'font-size': '9px',
          color: '#334155',
          'text-rotation': 'autorotate',
          'text-background-color': '#ffffff',
          'text-background-opacity': 0.9,
          'text-background-padding': '2px',
          'overlay-opacity': 0,
        },
      },
      {
        selector: 'node:selected',
        style: {
          'border-color': '#f59e0b',
          'border-width': 4,
        },
      },
    ],
    layout: {
      name: 'cose',
      animate: false,
      padding: 30,
      nodeRepulsion: 180000,
      idealEdgeLength: 140,
      edgeElasticity: 120,
    },
  };
}

function updateStats(containerId, payload) {
  const root = document.querySelector(`[data-stats-for="${containerId}"]`);
  if (!root) {
    return;
  }

  root.querySelector('[data-role="viewer"]').innerText = payload.viewer;
  root.querySelector('[data-role="nodes"]').innerText = payload.nodes.length;
  root.querySelector('[data-role="edges"]').innerText = payload.edges.length;

  const sharedCount = payload.nodes.filter((node) => (node.tags || []).includes('shared')).length;
  root.querySelector('[data-role="shared"]').innerText = sharedCount;
}

async function fetchGraph(company) {
  const response = await fetch(`/graph?company=${company}`);
  const payload = await response.json();
  if (!response.ok) {
    throw new Error(payload.error || payload.detail || 'Failed to load graph');
  }
  return payload;
}

async function loadGraph(company, containerId, titleId) {
  const container = document.getElementById(containerId);

  try {
    const payload = await fetchGraph(company);

    if (titleId) {
      const viewerTitle = payload.viewer === 'company-a' ? 'Sub A / Inventory Service' : 'Sub B / Shipping Service';
      document.getElementById(titleId).innerText = `Knowledge Graph View: ${viewerTitle}`;
    }

    updateStats(containerId, payload);

    const cy = cytoscape(baseGraphOptions(container, createElements(payload)));
    cy.fit(undefined, 30);
    return cy;
  } catch (error) {
    container.innerText = error.message;
    return null;
  }
}

async function loadCompareGraphs(companyA, companyB, leftContainerId, rightContainerId) {
  const [leftPayload, rightPayload] = await Promise.all([
    fetchGraph(companyA),
    fetchGraph(companyB),
  ]);

  updateStats(leftContainerId, leftPayload);
  updateStats(rightContainerId, rightPayload);

  const presetPositions = {};
  const allNodes = [...leftPayload.nodes, ...rightPayload.nodes];
  allNodes.forEach((node, index) => {
    if (!presetPositions[node.id]) {
      const angle = (index / allNodes.length) * Math.PI * 2;
      presetPositions[node.id] = {
        x: Math.cos(angle) * 220,
        y: Math.sin(angle) * 160,
      };
    }
  });

  const buildPresetElements = (payload) => [
    ...payload.nodes.map((node) => ({
      data: getNodeStyle(node),
      position: presetPositions[node.id],
    })),
    ...payload.edges.map((edge, index) => ({
      data: {
        id: `${edge.source}-${edge.target}-${edge.label}-${index}`,
        source: edge.source,
        target: edge.target,
        label: edge.label,
      },
    })),
  ];

  const makeGraph = (containerId, payload) => {
    const container = document.getElementById(containerId);
    const cy = cytoscape({
      ...baseGraphOptions(container, buildPresetElements(payload)),
      layout: {
        name: 'preset',
        padding: 30,
      },
    });
    cy.fit(undefined, 30);
    return cy;
  };

  const leftCy = makeGraph(leftContainerId, leftPayload);
  const rightCy = makeGraph(rightContainerId, rightPayload);

  const syncSelection = (source, target) => {
    source.on('select unselect', 'node', () => {
      target.nodes().unselect();
      source.nodes(':selected').forEach((node) => {
        const match = target.getElementById(node.id());
        if (match && match.length > 0) {
          match.select();
        }
      });
    });
  };

  syncSelection(leftCy, rightCy);
  syncSelection(rightCy, leftCy);

  return { leftCy, rightCy, leftPayload, rightPayload };
}

function populateCompareSummary(leftPayload, rightPayload) {
  const leftNodeLabels = new Set(leftPayload.nodes.map((node) => node.label));
  const rightNodeLabels = new Set(rightPayload.nodes.map((node) => node.label));

  const onlyLeft = [...leftNodeLabels].filter((label) => !rightNodeLabels.has(label)).sort();
  const onlyRight = [...rightNodeLabels].filter((label) => !leftNodeLabels.has(label)).sort();
  const shared = [...leftNodeLabels].filter((label) => rightNodeLabels.has(label)).sort();

  const writeList = (selector, values) => {
    const element = document.querySelector(selector);
    if (!element) {
      return;
    }
    element.innerHTML = values.map((value) => `<li>${value}</li>`).join('') || '<li>None</li>';
  };

  writeList('[data-compare="shared"]', shared);
  writeList('[data-compare="only-a"]', onlyLeft);
  writeList('[data-compare="only-b"]', onlyRight);
}

async function loadComparePage() {
  try {
    const { leftPayload, rightPayload } = await loadCompareGraphs(
      'company-a',
      'company-b',
      'graph-a',
      'graph-b'
    );
    populateCompareSummary(leftPayload, rightPayload);
  } catch (error) {
    document.getElementById('graph-a').innerText = error.message;
    document.getElementById('graph-b').innerText = error.message;
  }
}
