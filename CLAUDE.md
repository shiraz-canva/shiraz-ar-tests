# Canva AR App — Claude Context

## Project
iOS AR hackathon app (RealityKit + ARKit) that pulls designs from the Canva Connect API and places them in AR. Xcode project at `Shiraz's AR test/`.

## Canva Connect API — Confirmed Working Endpoints

### Auth
- OAuth flow via Vercel backend at `https://canva-ar-auth.vercel.app`
- App redirect URI: `https://canva-ar-auth.vercel.app/callback` (NOT `shiraz-s-ar-test.vercel.app` — that 404s)
- Always build auth URL with `URLComponents + queryItems`, never manual string concatenation with `.urlQueryAllowed` (leaves `:` and `/` unencoded, causes `invalid_request`)
- Scopes that work: `design:meta:read design:content:read` (do NOT add `asset:read` — unnecessary)
- URL scheme `canvaar` is registered in `Shiraz-s-AR-test-Info.plist`

### List Designs
- `GET /v1/designs` → `DesignListResponse { items: [CanvaDesign] }`

### Export Design (confirmed working 2026-05-05)
- **Start:** `POST /v1/exports` (NOT `/v1/designs/{id}/exports` — that 404s)
  ```json
  { "design_id": "DAXIrKICznQ", "format": { "type": "png" } }
  ```
- **Poll:** `GET /v1/exports/{jobId}`
- **Success response shape:**
  ```json
  { "job": { "id": "...", "status": "success", "urls": ["https://export-download.canva.com/..."] } }
  ```
  ⚠️ Response uses `urls: [String]` (flat array), NOT `pages: [{ download_url }]`

## Key Swift Files
| File | Purpose |
|------|---------|
| `CanvaAPIService.swift` | Auth + API calls |
| `ARViewContainer.swift` | All AR logic (RealityKit/ARKit) |
| `Models.swift` | API response structs + PlacementMode enum |
| `ContentView.swift` | Main UI |
| `Shiraz-s-AR-test-Info.plist` | URL scheme registration |
| `vercel-backend/api/callback.js` | OAuth token exchange |

## AR Placement Modes
- `.flat` — poster on horizontal surface (or via `placeYardSignMockup` for yard_sign format)
- `.mug` — cylinder mockup on floor
- `.tshirt` — procedural mesh, back camera tap-to-place, front camera face tracking
- `.phoneCase` — box mockup on floor
- `.frame` — procedural wood frame on vertical plane
- `.canvas` — gallery-wrap canvas on vertical plane
- `.banner` — floor-standing retractable banner with pole + base
- `.billboard` — large floor-standing billboard with two posts + backing board

## Format → Mode routing
- Tapping a format chip sets BOTH `selectedFormat` AND `placementMode` via `suggestedMode`
- `placeWithCurrentFormat` routes to the right placement function using both format.id and placementMode
- Yard sign special case: `.flat` mode + `format.id == "yard_sign"` → `placeYardSignMockup` (upright H-stake sign)

## Floor-standing upright panels — box approach (2026-05-05)
- **DO NOT use `generatePlane` + rotation** for banner/billboard/yard-sign faces — the X-rotation
  interacts unpredictably with the parent's yaw quaternion and produces flat or invisible faces.
- **USE `generateBox(size: [W, H, 0.001])`** instead. The box naturally has X=wide, Y=tall, Z=depth,
  so the front face (+Z) faces the camera without any rotation. 1mm depth means sides are invisible.
- Position: `entity.position = [0, H/2, clearance]` to stand from floor (y=0) to top (y=H).

## Key rotation rule for wall-mounted panels (frame, canvas)
- Vertical plane anchor: Y = wall normal (toward camera), X = horizontal, Z = world UP
- `generatePlane` normal (+Y) already faces camera → NO rotation needed on root
- Board/box: X=wide, Y=thin depth, Z=tall (i.e., `generateBox([dW, depth, dH])`)
- Billboard board WRONG: `[bbW, 0.018, bbH]` (thin in vertical!) → RIGHT: `[bbW, bbH, 0.018]`

## UI Architecture (ContentView.swift)
- Single "Choose a Product" horizontal scroll strip (replaces old dual Format + Mode pickers)
- Product cards: white background, shadow, purple border when selected, shows name + dimensions
- `ProductCard` is a private func returning `some View` (not a separate struct)
- Format selection auto-sets placementMode via `format.suggestedMode`
- Canva purple: `Color(red: 0.49, green: 0.17, blue: 0.91)` ≈ #7D2AE8

## Known Issues Fixed
- **ARFrame retention warnings:** Set `isBuilding = true` BEFORE dispatching to visionQueue, not after
- **Swift 6 concurrency warnings:** Coordinator must be `@MainActor`; remove `nonisolated` from ARSessionDelegate methods; mark `visionDetectAndPlace` as `nonisolated`
- **Front camera shirt:** `+π/2` X rotation (not `-π/2`), `flipV: true` for UVs, print at `[0, 0, -0.06]`
- **Back camera shirt:** print at `[0, 0, 0.06]` (shirt local Z = world UP)
- **Wall modes:** Use `ARRaycastQuery.TargetAlignment.vertical` and `ARCoachingOverlayView.goal = .verticalPlane`
- **Banner/Billboard/Yard sign face flat on floor:** `generatePlane + rotation` doesn't work reliably
  with a yaw-rotated parent. Switched to `generateBox(size: [W, H, 0.001])` — box stands upright natively.
- **Billboard board flat on floor:** Box dims were `[W, 0.018, H]` (thin vertically). Fixed to `[W, H, 0.018]`
- **Yard sign lying flat:** Was using `.flat` placement (horizontal plane). Fixed with dedicated `placeYardSignMockup` that stands upright
- **A2/A1 poster auto-adding wood frame:** `suggestedMode` was `.frame`. Changed to `.flat` — large posters
  should use flat placement, not automatically get a picture frame.
