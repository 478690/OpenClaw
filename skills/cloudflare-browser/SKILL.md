---
AIGC:
    ContentProducer: Minimax Agent AI
    ContentPropagator: Minimax Agent AI
    Label: AIGC
    ProduceID: "00000000000000000000000000000000"
    PropagateID: "00000000000000000000000000000000"
    ReservedCode1: 30450221009bf69ef0bdf368d216519d7638dd4f597cc6530b0ba02ef6a5a67411db8dc29302201699a5767bad12661e5fee42323150cc10114e526f3c4fea0a94984e47f565b9
    ReservedCode2: 3046022100ea3ce3de52ae0d3535ea4330238c36c618c47749d56ee606484dc32f24e7a34d0221009a3d0ca2c3f3d2557bab5ace7cf84118f458b5585b8928c717b027e4137bbbc2
description: Control headless Chrome via Cloudflare Browser Rendering CDP WebSocket. Use for screenshots, page navigation, scraping, and video capture when browser automation is needed in a Cloudflare Workers environment. Requires CDP_SECRET env var and cdpUrl configured in browser.profiles.
name: cloudflare-browser
---

# Cloudflare Browser Rendering

Control headless browsers via Cloudflare's Browser Rendering service using CDP (Chrome DevTools Protocol) over WebSocket.

## Prerequisites

- `CDP_SECRET` environment variable set
- Browser profile configured in openclaw.json with `cdpUrl` pointing to the worker endpoint:
  ```json
  "browser": {
    "profiles": {
      "cloudflare": {
        "cdpUrl": "https://your-worker.workers.dev/cdp?secret=..."
      }
    }
  }
  ```

## Quick Start

### Screenshot
```bash
node /path/to/skills/cloudflare-browser/scripts/screenshot.js https://example.com output.png
```

### Multi-page Video
```bash
node /path/to/skills/cloudflare-browser/scripts/video.js "https://site1.com,https://site2.com" output.mp4
```

## CDP Connection Pattern

The worker creates a page target automatically on WebSocket connect. Listen for Target.targetCreated event to get the targetId:

```javascript
const WebSocket = require('ws');
const CDP_SECRET = process.env.CDP_SECRET;
const WS_URL = `wss://your-worker.workers.dev/cdp?secret=${encodeURIComponent(CDP_SECRET)}`;

const ws = new WebSocket(WS_URL);
let targetId = null;

ws.on('message', (data) => {
  const msg = JSON.parse(data.toString());
  if (msg.method === 'Target.targetCreated' && msg.params?.targetInfo?.type === 'page') {
    targetId = msg.params.targetInfo.targetId;
  }
});
```

## Key CDP Commands

| Command | Purpose |
|---------|---------|
| Page.navigate | Navigate to URL |
| Page.captureScreenshot | Capture PNG/JPEG |
| Runtime.evaluate | Execute JavaScript |
| Emulation.setDeviceMetricsOverride | Set viewport size |

## Common Patterns

### Navigate and Screenshot
```javascript
await send('Page.navigate', { url: 'https://example.com' });
await new Promise(r => setTimeout(r, 3000)); // Wait for render
const { data } = await send('Page.captureScreenshot', { format: 'png' });
fs.writeFileSync('out.png', Buffer.from(data, 'base64'));
```

### Scroll Page
```javascript
await send('Runtime.evaluate', { expression: 'window.scrollBy(0, 300)' });
```

### Set Viewport
```javascript
await send('Emulation.setDeviceMetricsOverride', {
  width: 1280,
  height: 720,
  deviceScaleFactor: 1,
  mobile: false
});
```

## Creating Videos

1. Capture frames as PNGs during navigation
2. Use ffmpeg to stitch: `ffmpeg -framerate 10 -i frame_%04d.png -c:v libx264 -pix_fmt yuv420p output.mp4`

## Troubleshooting

- **No target created**: Race condition - wait for Target.targetCreated event with timeout
- **Commands timeout**: Worker may have cold start delay; increase timeout to 30-60s
- **WebSocket hangs**: Verify CDP_SECRET matches worker configuration
