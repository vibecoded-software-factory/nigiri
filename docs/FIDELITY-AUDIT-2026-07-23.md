# Auditoría de fidelidad nigiri ↔ niri — 2026-07-23

> Cinco auditores paralelos compararon nigiri contra un clon fresco de
> https://github.com/niri-wm/niri (HEAD `7f26c3e`). Regla de oro ("el norte"):
> 100% fiel a niri; solo se aceptan desviaciones estrictamente forzadas por
> macOS. Toda afirmación tiene refs `archivo:línea` de ambos lados en los
> reportes de agente; aquí está la destilación accionable.
>
> **Totales: 82 violaciones del norte · 38 desviaciones justificadas ·
> ~70 comportamientos verificados fieles.**

## Patrones transversales (la firma de la alucinación)

1. **Comentarios que citan a niri afirmando lo contrario de lo que niri hace** —
   los casos confirmados:
   - `Engine/TilingEngine+Workspaces.swift:143-150` — "niri creates workspaces
     up to N instead of clamping". Falso: `monitor.rs:1011-1013` clampea.
   - `Engine/TilingEngine+Actions.swift:518-522` — "cycle by INDEX, not by
     first-preset-wider". Falso: `floating.rs:641-673` usa exactamente esa
     comparación como fallback.
   - `Engine/TilingEngine+Actions.swift:390-401` — `captureHeightWeights`
     atribuido a `convert_heights_to_auto`; upstream la ejecuta en otro momento
     y con otro efecto (`scrolling.rs:5070-5083`).
   - `Engine/TilingEngine+Animation.swift:78-80` — cita `animations.rs:145`
     como fuente del spring 800; esa línea define workspace-switch = **1000**.
   - `Input/HotkeyListener.swift:36-37` — "the same knobs niri reads from
     libinput"; niri usa su propia config repeat-delay/rate, no libinput.
2. **Vocabulario inventado**: `resize-edge` (¡en los binds por defecto!),
   sección `wheel {}`, claves de `gestures {}` (`three-finger-*`…),
   `open-on-workspace <int>`, `focus-window-by-id`, alias `gap`, alias
   `consume-or-expel-left/right`, protocolo bare-word por socket, FIFO
   `CommandPipe` (`/tmp/nigiri-cmd`).
3. **Defaults inventados**: `border.inactive = #585B70` (Catppuccin; upstream
   `#505050`), spring 800 universal, screenshot-path en `~/Desktop`, sombra
   alpha 0.45, gap compilado 10 (upstream 16), ghost escala 0.85 (upstream 0.8),
   clamps de overview.zoom y slowdown.
4. **Semántica invertida o silenciada**: `shadow {}` enciende / `border {}` no
   enciende (upstream es al revés en ambos), SizeChange absoluto→delta en
   flotantes, acciones desconocidas responden `{"Ok":"Handled"}`.
5. **Modelo de tipos degradado**: falta `ColumnWidth::Fixed`, `WindowHeight`
   como enum (Auto/Fixed/Preset), estados fullscreen/full-width por columna,
   rubber band y SwipeTracker completos.

---

## 1. IPC / `niri msg` (12 violaciones · 5 justificadas · 10 fiel)

**Vara: "un cliente `niri msg` real funciona sin modificar" → NO se cumple.**

Críticas:
- **V1** Eventos legacy `{"event":...}` inyectados en el MISMO socket del event
  stream (`TilingEngine+Workspaces.swift:296`, `+Animation.swift:149`,
  `+Navigation.swift:242`, `+Layout.swift:918-920`, `+Overview.swift:58,414,519,541`)
  → todo `Socket::read_events()` upstream muere con `unknown variant "event"`.
- **V2** `Window` sin `is_urgent` (obligatorio, `niri-ipc/src/lib.rs:1360`) ni
  `focus_timestamp` → `niri msg windows`/`focused-window` no deserializa.
  (`IPC/NiriProtocol.swift:160-188`).
- **V3** Decodificador de `Action` con pérdida (`NiriProtocol.swift:96-117`):
  la rama Bool es código muerto (NSNumber matchea Int antes — verificado
  empíricamente: `focus:true` → arg posicional `1` → mueve al workspace 1);
  `Spawn{command:[...]}` se descarta entero; `SizeChange` en forma JSON niri
  no parsea.
- **V4** Acciones desconocidas/malformadas responden `{"Ok":"Handled"}`
  (`NiriProtocol.swift:338-340`); upstream devuelve `Err` (`server.rs:205-214`).

Moderadas: **V5** faltan Requests `Layers/KeyboardLayouts/PickColor/Output/ReturnError/Casts`
(varios trivialmente implementables); **V6** `Transform` emitido en minúsculas
(`"normal"`) — wire format upstream es `"Normal"` → rompe `niri msg outputs`;
**V7** una petición por conexión (upstream es bucle); **V8** ráfaga inicial del
stream incompleta (faltan `KeyboardLayoutsChanged`, `CastsChanged`; sobra
`WindowFocusChanged`) y 10 variantes de `Event` nunca emitidas — la peor:
`WindowLayoutsChanged` (cambios solo-geometría jamás llegan a clientes).

Menores: **V9** `WorkspaceActivated` siempre `focused:true`; **V10**
`pos_in_scrolling_layout` inconsistente entre `Windows` y `FocusedWindow`/`PickWindow`;
**V11** ~40 variantes de `Action` sin case en el dispatch (incl. `set-window-width`)
con éxito silencioso; **V12** superficie inventada (bare-word, `struts`,
workspaces reportando siempre la primera pantalla como output).

Justificadas: socket en `/tmp/nigiri-msg.sock` (sin XDG en macOS, exporta
`NIRI_SOCKET` fiel), `Version` propio, `PickWindow` sin grab, campos de
`Output` en null honesto, desconexión de suscriptores lentos sin buffer.

## 2. Configuración (26 violaciones · 9 justificadas · 12 fiel)

Graves:
- **A1** Raw strings KDL rotos en posición de propiedad
  (`ConfigParser.swift:37`): `app-id=r#"…"#` — la forma que usa el propio
  `default-config.kdl` de niri — se corrompe en silencio y las window-rules
  jamás matchean.
- **A2/A3** Semántica invertida: `shadow {}` enciende (upstream off,
  `appearance.rs:355`); `border {}` no enciende (upstream ON con width 4) y
  `border { active-color }` se rechaza con un sermón inventado.
- **A4** Default inventado `border.inactive = #585B70` (upstream `#505050`).
- **A5** Regexes forzados a case-insensitive (`Regex.swift:13`); upstream es
  case-sensitive.
- **A6/A7** Secciones inventadas `wheel {}` y claves de `gestures {}`; los
  gestos de niri son fijos, su `gestures {}` solo tiene `dnd-edge-*` y
  `hot-corners`.
- **A8** `open-on-workspace <int>` inventado (upstream solo nombre).
- **A9** `default-column-width { fixed … }` y el bloque vacío (= ancho natural
  de la ventana) se pierden en silencio.
- **A10** `resize-edge` inventado e incluido en binds por defecto.
- **A11** Defaults de animación equivocados (ver §4).
- **A12** `include`: sin `optional=`, ausente no-opcional no es error, sin `~`,
  dedup global incorrecto, expandido dentro de secciones.

Medias/menores (selección): clamps inventados de `overview.zoom` y `slowdown`;
screenshot-path default inventado y `screenshot-path null` roto; solo colores
hex (upstream acepta CSS names/rgb()/hsl()); `Flag false` ignorado;
`environment { K null }` no des-setea; `tab-indicator` y `focus-ring` rechazan
claves upstream válidas (angle default 45 vs 180 upstream); binds/secciones
duplicados sin error; `mod-key` con valores inventados (`hyper`, `cmd`…);
rangos sin validar. El default config generado (`ConfigDefault.swift:142-226`)
reinventa el keymap entero en vez de portar el upstream con Mod remapeado.

Justificadas: Mod=Cmd+Opt, resolución de teclas TIS/UCKeyTranslate, `app-id` ≈
bundle-id, ruta `~/.config/niri/config.kdl` con fallback, secciones
Wayland-only saltadas limpias, live-reload con includes.

Ausencias upstream relevantes: `hotkey-overlay {}`, hijos de `workspace {}`
(overrides de layout), `workspace-auto-back-and-forth`, decenas de window-rules
(`open-on-output`, `default-window-height`, `block-out-from`…), animaciones
`config-notification-open-close`/`exit-confirmation`/`screenshot-ui-open`.

## 3. Layout core (17 violaciones · 8 justificadas · ~20 fiel)

Graves:
- **V1** Resize flotante: `SetProportion`/`SetFixed` tratados como DELTA
  (`SizeChange.swift:26-31` + `Actions.swift:118-130`) — el mismo bug que el
  comentario del archivo declara corregido, reintroducido para flotantes.
  Además usa pantalla cruda en vez de working area y piso 50px inventado.
- **V2** `setWindowHeight` tiled con fórmulas propias y piso/techo inventados
  (20px); no usa el helper fiel `height(forProportion:)` que ya existe
  (`LayoutEngine.swift:161-163`); rompe el invariante upstream "solo una
  ventana no-Auto por columna" (`scrolling.rs:244-247`).
- **V3** `captureHeightWeights` congela ratios en consume/expel; upstream
  re-equaliza (tile nuevo entra `auto_1()`).
- **V4** Fullscreen no extrae la ventana a columna propia
  (upstream: `scrolling.rs:2840-2845` hace consume_or_expel primero) y el
  estado es por-workspace en vez de por-columna.

Moderadas: **V5** `maximize-column` único por workspace (upstream:
`is_full_width` por columna, múltiples a la vez); **V6** no existe
`ColumnWidth::Fixed` — px pedidos se degradan a proporción y derivan al cambiar
de monitor (lo contrario de la motivación documentada upstream,
`scrolling.rs:249-255`); **V7** ciclo de presets hacia atrás roto (semilla
`firstWider-1` en vez de last-narrower) en flotante y altura; **V8** preset de
altura materializado a px en vez de `Preset(idx)` re-resoluble; **V9**
expel/toggle-floating→tiled no heredan el ancho de origen (caen al 0.5).

Menores: `set-window-width` ausente; gap compilado 10 vs 16; maximizada no
anula el fast-path del índice de presets; `expandColumnToAvailableWidth` sin
3 ramas upstream; `centerVisibleColumns` sin guards; `insertPosition` hovered
por contención estricta; salir de tabbed no cancela fullscreen/maximized;
`resize-edge` inventado.

Justificadas: parking 1px x-only, probing de min-sizes vía AX (sin protocolo),
flotantes no re-posicionadas, overlays sin `extra_size`, struts con
reserve-zone (sustituto de layer-shell), `native-fullscreen` como escape
documentado, animador propio sin transactions Wayland.

Fiel (verificado): fórmulas de ancho/inversa, clamp min/max floor-wins,
presets ⅓/½/⅔, scroll/cámara completo (fully-visible, menor movimiento,
centrado, OnOverflow contra vecino), `insertPosition` centros de gap,
`naiveHeights`, `activate_prev_column_on_removal`, consume/expel completo,
flotante direccional 50px, `SizeChange.parse`, workspaces dinámicos con
`empty-workspace-above-first`.

## 4. Input, gestos, animaciones (10 violaciones · 7 justificadas · 7 fiel)

Graves:
- **V1** No hay tabla de defaults por animación: TODO cae en spring 800
  (`TilingEngine+Animation.swift:72-81`). Upstream: workspace-switch spring
  **1000**; window-open easing 150ms ease-out-expo; window-close easing 150ms
  ease-out-quad; config-notification spring 1000/0.6; etc. El fallback
  workspace-switch→window-movement también es inventado.
- **V2** El modelo de gesto continuo de niri (SwipeTracker: HISTORY 150ms,
  decel 0.997, umbral de eje 16px, 300px/workspace, 1200px/vista, proyección
  de inercia, snapping) fue sustituido por un reconocedor discreto con
  constantes inventadas (threshold 0.18, cooldown 0.4s). MultitouchSupport
  entrega posiciones continuas — NO está bloqueado por macOS.

Medias: **V3** `rubber_band.rs` ausente por completo; **V4** cubic-bezier
evaluado en t sin resolver x (upstream: bisección `t_for_x`, 30 iter — la
definición CSS); **V5** interactive move sin umbral 256px ni rubber band de
arranque.

Menores: ghost de cierre escala 0.85 (upstream termina en 0.8); parser de
animaciones con defaults/fallbacks propios (spring incompleto no es error,
`curve` sin `duration-ms` descartada); pisos inventados en Spring y settle
sobreamortiguado incorrecto (termina antes de tiempo si ζ>1; falta
`initial_velocity` y `clamped_duration`); overview: rueda sin acumulador v120
ni cooldown 50ms; mapeo CA genérico para ease-out-quad/cubic cuando tienen
bezier exacto.

Justificadas: animador 120Hz con corte 3px (coste AX, medido), Carbon
RegisterEventHotKey, window-open sin animación (textura inexistente), guard de
momentum 0.15s, CASpringAnimation (mapeo exacto), slowdown como stiffness/s²
(equivalente), hot corner por polling.

Fiel: matemática del spring (3 regímenes idénticos con v0=0), defaults
1.0/800/0.0001 correctos para window-movement/resize/horizontal-view/overview,
curvas easing exactas, semántica de binds (press, repeat, cooldown-ms,
hotkey-overlay-title null), hot corners, scroll de overview
discreto-vs-continuo, regla de drop de DnD.

## 5. Acciones, navegación, overview, screenshot, chrome (17 violaciones · 9 justificadas · ~25 fiel)

Altas:
- **V1** `focus-workspace N` CREA workspaces hasta N; niri clampea
  (`monitor.rs:1011-1013`). Ídem el relativo (último workspace → no-op
  upstream). Comentario con cita falsa (ver patrones).
- **V2** = SizeChange flotante (mismo hallazgo que Layout V1, confirmado
  independientemente).

Medias: **V3** `move-column-to-workspace` con flotante activa es no-op (niri
mueve la flotante); **V4** columna movida se apendiza al FINAL y roba foco
incluso con `focus:false` (niri: junto a la activa del destino, sin tocar
foco); **V5** navegación flotante con dominancia de eje + euclídea (niri:
distancia axial pura; first/last/top/bottom geométricos, no por índice de
lista); **V6** `center-column` y `switch-preset-column-width` no-op en
flotantes (niri opera sobre la flotante); **V7** screenshot sin portapapeles
(upstream SIEMPRE copia), sin flags `show-pointer`/`path`/`id`, captura la
pantalla principal en vez de la enfocada; **V8** cualquier acción no-navegación
colapsa el overview (niri lo mantiene abierto); **V9** scroll de overview:
rueda opera sobre la selección en vez del workspace bajo el cursor, continuo
convertido en pan horizontal; **V10** hotkey overlay reinventado (lista todo y
roba foco; upstream: lista curada ~15, alpha 0.9, sin foco).

Bajas: `move-workspace-up/down` no restaura invariantes en el acto ni
relayouta; `empty-workspace-above-first` con todo vacío deja 2 (upstream
colapsa a 1); semilla hacia atrás de presets (= Layout V7); `focus-column <n>`
no sale de la capa flotante; overview con backdrop-wallpaper y anillo de
selección con glow inventados (upstream: gris 0.15, sin anillo propio);
config-error notification inexistente (solo print); tab indicator no
configurable ni con fallback de color al ring/border; acciones ausentes
(`focus-window-or-workspace-*`, `focus-window-in-column`,
`focus-*-or-monitor-*`, `move-workspace-to-monitor-*`,
`workspace-auto-back-and-forth`, param `id=` en casi todas); renombrado de
workspaces por posición en cada reload.

Justificadas: strip inferior + parking (sin API de Spaces), overview como
panel de thumbnails SCK (geometría del zoom sí portada fiel: 0.5, clamp
0.0001–0.75), fullscreen windowed + `native-fullscreen`, expulsión si el stack
no cabe (AX sin min-heights), `screencapture` del sistema, chrome como
overlays, NSAlert para quit, reserve/clear-zone, Escape/Enter en overview.

Fiel: focus-column sin wrap y `-or-first/last`, focus-window-up/down/top/bottom,
consume/expel completo, swap-window, presets tiled, expand-column,
center-column tiled, workspaces dinámicos y clamps de move-to-workspace,
toggle-window-floating, clicks/drags del overview, y la distinción
focus-ring vs border con los defaults exactos de niri.

---

## Plan de corrección priorizado

**Quick wins (diffs chicos, arreglan compatibilidad real):**
1. `is_urgent: false` + `focus_timestamp: null` en `niriWindow` (2 líneas;
   desbloquea `niri msg windows`).
2. `Transform` → `"Normal"` (1 línea; desbloquea `niri msg outputs`).
3. Sacar los eventos legacy `{"event":...}` del socket del event stream.
4. Tabla de defaults por animación + eliminar fallback workspace-switch.
5. Semántica `border {}`/`shadow {}` + inactive `#505050` + permitir
   `border { active-color }`.
6. Fix raw strings en posición de propiedad del tokenizer KDL.
7. Ghost 0.85→0.8; regex case-sensitive; semilla last-narrower en presets
   hacia atrás; gap compilado 16.
8. `t_for_x` por bisección para cubic-bezier.
9. `focus-workspace` clampeando en vez de crear.

**Estructurales (requieren cirugía de modelo):**
- Reescribir el decodificador de `Action` (campos con nombre, Bool antes que
  Int, `Err` en desconocidas) + bucle de peticiones por conexión.
- `ColumnWidth::Fixed` + `WindowHeight` enum (Auto/Fixed/Preset) + invariante
  una-no-Auto + estados fullscreen/full-width por columna.
- SizeChange flotante con semántica set/adjust real sobre working area.
- Portar `rubber_band.rs` + `SwipeTracker` (o registrar los gestos discretos
  como desviación consciente en CLAUDE.md).
- Purgar vocabulario inventado (`resize-edge`, `wheel{}`, claves de gestures,
  bare-word IPC, `CommandPipe`) o documentarlo como extensión no-niri.
- Overview: mantener abierto durante acciones; rueda sobre workspace bajo
  cursor.
- Portar el keymap del `default-config.kdl` upstream con Mod remapeado en vez
  del keymap reinventado.

**Regla derivada de esta auditoría:** todo comentario en nigiri que cite un
`archivo:línea` de niri debe verificarse contra el clon real antes de confiar
en él — se confirmaron 5 citas falsas.

---

## Checklist de trabajo (82 ítems, iterar por ID)

Severidad: 🔴 grave · 🟠 media · 🟡 menor. Marcar con fecha al cerrar.

### IPC (12)
- [x] **IPC-1** 🔴 DONE 2026-07-23 (streams separados: `broadcastLegacy` solo a suscriptores bare-word; verificado en vivo: stream niri sin líneas legacy, legacy conserva las suyas) — Eventos legacy `{"event":...}` inyectados en el socket del event stream
- [x] **IPC-2** 🔴 DONE 2026-07-23 (`is_urgent: false` + `focus_timestamp: null` en `niriWindow`; verificado en vivo sobre 3 ventanas) — `Window` sin `is_urgent` ni `focus_timestamp`
- [x] **IPC-3** 🔴 DONE 2026-07-23 (decoder reescrito: Bool por CFTypeID antes que Int, Spawn array, SizeChange tagged-enum → forma string, snake_case→kebab, window_id kv; `workspaceRefArg` en dispatch; 7 checks nuevos en selftest + verificado en vivo) — Decodificador de `Action` con pérdida
- [x] **IPC-4** 🔴 DONE 2026-07-23 (`performAction` → Bool; desconocida/malformada → `{"Err":...}`, verificado en vivo en ambos sobres) — Acciones desconocidas respondían `Ok`
- [x] **IPC-5** 🟠 DONE 2026-07-23 (Layers:[], KeyboardLayouts con TIS real, Casts:[], ReturnError verbatim, Output→OutputWasMissing/Err honesto, PickColor→null honesto (SCK es async-a-main, sample síncrono deadlockearía); verificado en vivo los 6; 6 checks de parseo) — Requests ausentes: `Layers`, `KeyboardLayouts`, `PickColor`, `Output`, `ReturnError`, `Casts`
- [x] **IPC-6** 🟠 DONE 2026-07-23 (`"Normal"`; verificado en vivo) — `Transform` en minúsculas rompía `niri msg outputs`
- [x] **IPC-7** 🟠 DONE 2026-07-23 (bucle de peticiones por conexión como server.rs:191-268, EOF = colgado, stream interleaved; verificado en vivo: 7 requests/7 replies por un socket) — Una petición por conexión; upstream procesa en bucle
- [x] **IPC-8** 🟠 DONE 2026-07-23 (ráfaga = replicate() exacto: workspaces, windows, keyboard_layouts (TIS real), overview, config, casts — verificado en vivo; WindowFocusChanged fuera del seed; WindowLayoutsChanged emitiendo en cada cambio de geometría vía settledFrame — lastActualFrame era el memo de rechazos, siempre nil, diagnóstico en vivo; KeyboardLayoutSwitched/-Changed desde el observer TIS; ScreenshotCaptured tras cada captura; quedan dormidos los de urgencia/focus_timestamp/casts hasta que exista esa maquinaria) — Ráfaga inicial del stream incompleta + 10 variantes de `Event` nunca emitidas (peor: `WindowLayoutsChanged`)
- [x] **IPC-9** 🟡 DONE 2026-07-23 (`focused` lo declara el caller; hoy siempre true porque el modelo tiene un solo workspace enfocado — documentado, ya no cableado en el wire) — `WorkspaceActivated` siempre `focused: true`
- [x] **IPC-10** 🟡 DONE 2026-07-23 (serializador único niriWindowLocated para FocusedWindow/PickWindow/eventos; tile_pos_in_workspace_view relativo al working area (la vista de gradientes), null para ventanas aparcadas — Option upstream, null > basura; verificado en vivo: FocusedWindow == Windows) — `pos_in_scrolling_layout` inconsistente entre `Windows` y `FocusedWindow`/`PickWindow`; coords absolutas vs vista
- [x] **IPC-11** 🟡 DONE 2026-07-23 (implementadas todas las variantes implementables: familia -or- completa (window/column/workspace/monitor), focus-window-in-column, move-window/column-or-to-*, focus/move-monitor-next/previous, move-workspace-to-monitor (los 6), switch-layout vía TIS real (verificado en vivo 1→0→1), move-floating-window (delta +40,-20 exacto en vivo), workspace-auto-back-and-forth; las sin maquinaria (urgencia, opacity-rule, casts, screen-transition, inhibit, power-monitors, load-config-file) responden Err honesto vía IPC-4 — el éxito silencioso ya no existe) — ~40 variantes de `Action` sin case en dispatch (incl. `set-window-width`) con éxito silencioso
- [x] **IPC-12** 🟡 DONE 2026-07-23 (FIFO CommandPipe eliminado — sin consumidores, `nigiri msg action` lo cubre, CLAUDE.md actualizado; request struts eliminado; bare-word event-stream/action SE QUEDA documentado como extensión porque bento lo habla — decisión marcada; output por workspace = el dueño real vía Output.workspaces, ya no la primera pantalla; verificado en vivo) — Superficie inventada: protocolo bare-word, request `struts`, `CommandPipe`, output siempre = primera pantalla

### Config (26)
- [x] **CFG-1** 🔴 DONE 2026-07-23 (tokenizer acepta raw string tras `=`; 2 checks nuevos en selftest, 399 verdes; check-config parsea la regla de WezTerm del default de niri) — Raw strings KDL rotos en posición de propiedad
- [x] **CFG-2** 🔴 DONE 2026-07-23 (`shadow {}` ya no enciende; solo `on` explícito; selftest corregido — afirmaba la semántica invertida) — `shadow {}` encendía la sombra
- [x] **CFG-3** 🔴 DONE 2026-07-23 (modelo `borderOn` + caso especial `border {}`→ON, width default 4, `active-color`/`active-gradient` aceptados; con ring off + border on la activa viste el color activo del border; 4 checks en selftest) — `border {}` no encendía
- [x] **CFG-4** 🔴 DONE 2026-07-23 (defaults = `Border::default()`: inactive `#505050`, active `#ffc87f`; ConfigDefault.swift actualizado) — Default inventado `#585B70`
- [x] **CFG-5** 🔴 DONE 2026-07-23 — Regexes de matchers forzados a case-insensitive (upstream case-sensitive)
- [x] **CFG-6** 🔴 DONE 2026-07-23 (sección wheel{} eliminada del parser y del default config; los wheel binds van como binds normales Mod+WheelScrollDown, la forma de niri, con tests reescritos a esa forma) — Sección top-level `wheel {}` inventada
- [x] **CFG-7** 🔴 DONE 2026-07-23 (three-finger-*/four-finger-*/mouse-* purgados de parser, Config, engine y default config - ahora caen a unknown-key con warning; gestures{} queda con el vocabulario real de niri: hot-corners [parseado] y dnd-edge-view-scroll/dnd-edge-workspace-switch [reconocidos y skipeados, sin contraparte macOS aún]; los gestos 3/4 dedos son hardcodeados y continuos como upstream, nunca configurables; tu gestures.kdl [hot-corners{off}] parsea sin warnings) — Claves inventadas en `gestures {}` (`three-finger-*`, `four-finger-*`, `mouse-*`); defaults ni siquiera replican niri
- [x] **CFG-8** 🔴 DONE 2026-07-23 (open-on-workspace = NOMBRE siempre, window_rule.rs:25-26; "2" es un workspace llamado 2; check en selftest) — `open-on-workspace <int>` inventado (upstream solo nombre)
- [x] **CFG-9** 🔴 DONE 2026-07-23 (DefaultWidth proportion/fixed/natural; bloque vacío = la ventana decide (Some(None)); resuelto por ventana en adopción; fixed vía proportion(forWidth:) hasta LAY-6; 7 checks) — `default-column-width { fixed }` y bloque vacío (= ancho natural) se pierden en silencio
- [x] **CFG-10** 🔴 DONE 2026-07-23 (acción resize-edge purgada de dispatch, junto con focus-window-by-id y los alias consume-or-expel-left/right; ya no estaba en los binds default desde CFG-27; verificado en vivo: responde Err) — Acción `resize-edge` inventada e incluida en binds por defecto (+ `reserve-zone`/`clear-zone`/`native-fullscreen`/`focus-window-by-id`/alias `consume-or-expel-*` en dispatch)
- [x] **CFG-11** 🔴 DONE 2026-07-23 — Defaults de animación equivocados (ver ANI-1); parser: `duration-ms` sin `curve` fuerza easeOutCubic, `curve` sin `duration-ms` se descarta
- [x] **CFG-12** 🔴 DONE 2026-07-23 (expandIncludes reescrito con la semantica de niri lib.rs:297-443: solo top-level fuera de llaves/comillas, optional=true, requerido faltante = fallo de carga completo -> banner, expansion de ~, recursion detectada por rama via stack, tope de profundidad 10, lastLoadedFiles del set realmente leido; 6 selftests nuevos; config real del usuario valida) — `include` divergente: sin `optional=`, ausente no es error, sin `~`, dedup global, expandido dentro de secciones, límite 20 vs 10
- [x] **CFG-13** 🟠 DONE 2026-07-23 (acepta 0..1 como FloatOrInt<0,1>, fuera de rango rechaza con reporte; el clamp de render 0.0001-0.75 queda en el overview como upstream; 2 checks) — `overview.zoom` clampeado a [0.1, 0.95] (upstream [0,1])
- [x] **CFG-14** 🟠 DONE 2026-07-23 — `animations.slowdown` con piso 0.01 (upstream permite 0)
- [x] **CFG-15** 🟠 DONE 2026-07-23 (default = ~/Pictures/Screenshots de misc.rs:60-64; `null` → clipboard-only; 2 checks) — screenshot-path default inventado (`~/Desktop/…`); `screenshot-path null` guardado como ruta literal
- [x] **CFG-16** 🟠 DONE 2026-07-23 (alpha 0x77/255; spread parseado y plegado al blur del CALayer (sin spread real), default 5; 2 checks) — Sombra: alpha 0.45 vs ≈0.467; `spread` descartado
- [x] **CFG-17** 🟠 DONE 2026-07-23 (csscolorparser completo: 148 nombres CSS, rgb()/rgba()/hsl()/hsla() con %, forma nodo RGBA de 4 números (appearance.rs:798-815), rejoin de tokens para funciones con espacios; 4 checks) — Colores solo hex; upstream acepta CSS names, `rgb()`, `hsl()`, forma nodo RGBA
- [x] **CFG-18** 🟠 DONE 2026-07-23 (Flag con `false` explícito en los 4 sitios, utils.rs:17-24; check) — Semántica `Flag`: `option false` ignorado (activa por presencia)
- [x] **CFG-19** 🟠 DONE 2026-07-23 (environment [String: String?]; `K null` des-setea, string vacío setea vacío; 2 checks) — `environment { K null }` asigna `"null"` en vez de des-setear
- [x] **CFG-20** 🟠 DONE 2026-07-23 (vocabulario completo de appearance.rs:459-499: off/on, hide-when-single-tab, place-within-column, gap, width, length total-proportion, position left/right/top/bottom, gaps-between-tabs, corner-radius, urgent-* (dormantes hasta urgencia); geometría del overlay configurable; colores unset derivan del ring/border como tab_indicator.rs:363-406; 2 checks) — `tab-indicator`: claves upstream reales rechazadas como unknown
- [x] **CFG-21** 🟠 DONE 2026-07-23 (urgent-color/urgent-gradient e inactive-gradient aceptados; angle CSS arbitrario con default 180 renderizado en el CAGradientLayer; relative-to reportado como per-window; corner-radius documentado como extensión macOS medida; 3 checks) — `focus-ring`: faltan `urgent-*`/`inactive-gradient`; gradiente ignora `relative-to`/`in`; angle default 45 vs 180; `corner-radius` clave inventada
- [x] **CFG-22** 🟠 DONE 2026-07-23 (duplicado intra-sección: reporte + gana el primero (niri rechaza el config, binds.rs:776-812); entre secciones el nuevo REEMPLAZA (lib.rs:219-231); 2 checks) — Binds duplicados acumulados (upstream: error intra-bloque, replace entre partes)
- [x] **CFG-23** 🟠 DONE 2026-07-23 (secciones singleton duplicadas reportadas; se fusionan como los config parts de niri — el límite de archivo se pierde al expandir includes, documentado; sin falsos positivos en el config real del usuario) — Secciones duplicadas fusionadas en silencio (upstream: error)
- [x] **CFG-24** 🟠 DONE 2026-07-23 (spellings exactos de ModKey (input.rs:439-453): ctrl|control, shift, alt, super|win, iso_level3_shift|mod5→Option, iso_level5_shift|mod3→Option con aviso; cmd/command/opt/option/hyper eliminados con checks de rechazo; mod-key-nested queda inerte-documentado pendiente de parse) — `mod-key`: valores inventados (`cmd`, `hyper`, …), faltan los reales, falta `mod-key-nested`; modificador `Hyper` en combos inventado
- [x] **CFG-25** 🟠 DONE 2026-07-23 (input.keyboard.xkb.layout real con lista separada por comas — el primero pinea los binds; pre-pass busca xkb, no el token inventado; binds-layout/keyboard-layout eliminados; check) — `binds-layout`/`keyboard-layout` nombres inventados (análogo real: `input.keyboard.xkb.layout`); pre-pass con falsos positivos
- [x] **CFG-26** 🟠 DONE 2026-07-23 (gaps validado a FloatOrInt<0,65535>; alias `gap` eliminado; typo en center-focused-column reporta en vez de volverse `never`; nombres de animación desconocidos reportados y no almacenados; springs ya validados en ANI-7; 4 checks) — Rangos sin validar (gaps negativos, spring), alias `gap`, `center-focused-column` desconocido cae a `never`, animaciones desconocidas aceptadas
- [x] **CFG-27** 🟡 DONE 2026-07-23 (keymap default = default-config.kdl:349-633 tecla por tecla con Mod=Cmd+Opt: vi HJKL, monitores en Mod+Shift, brackets, wheel binds con cooldown-ms=150, Mod+O/Q/R/F/M/C/V/W, Mod+Shift+E quit; omisiones macOS-forzadas comentadas (XF86, Print, inhibit, power-off); el keymap reinventado y Hyper+Escape eliminados; 3 checks incl. >80 binds parseando) — (bonus F) `ConfigDefault.swift` reinventa el keymap entero en vez de portar `default-config.kdl` con Mod remapeado

### Layout core (17)
- [x] **LAY-1** 🔴 DONE 2026-07-23 — Resize flotante: `SetProportion`/`SetFixed` tratados como DELTA; pantalla cruda vs working area; piso 50px inventado
- [x] **LAY-2** 🔴 DONE 2026-07-23 — `setWindowHeight` tiled: fórmulas propias, piso 20px inventado, no usa `height(forProportion:)`; rompe invariante "una sola no-Auto por columna"
- [x] **LAY-3** 🔴 DONE 2026-07-23 — `captureHeightWeights` en consume/expel congela ratios; upstream re-equaliza (`auto_1()`)
- [x] **LAY-4** 🔴 DONE 2026-07-23 (extraccion: consume_or_expel_window_right antes de fullscreenear [scrolling.rs:2840-2845]; estado por-COLUMNA: is_pending_fullscreen/is_pending_maximized en Column [scrolling.rs:171-175], Workspace.fullscreenWindow/fullscreenToEdges ahora DERIVADOS del flag de la columna - los invariantes son estructurales (ventana que sale de la columna deja de ser fullscreen, columna que muere se lleva el flag, columna movida llega fullscreen) y cayeron 4 sitios de cancelacion manual; verificado en vivo: columna fullscreen movida a otro workspace LLEGA fullscreen [1470x924 intacto], to-edges 1470x912 vs fullscreen 1470x924 vs off exactos) — reestructuración permanente; el ESTADO sigue por-workspace: equivalente observable bajo la desviación del parking, pendiente si se quiere el modelo por-columna) — Fullscreen no extrae a columna propia (upstream: consume_or_expel primero); estado por-workspace vs por-columna
- [x] **LAY-5** 🟠 DONE 2026-07-23 (is_full_width ahora es un flag DE LA COLUMNA como scrolling.rs:170: Workspace.maximizedIndex y todo su re-anclaje eliminados; toggle_full_width per-column [scrolling.rs:4909], set_column_width lo limpia [4906], expand lo respeta [2814], open-maximized lo pone en la columna; verificado en vivo: DOS columnas full-width a la vez [1450px ambas], apagar una no toca la otra) — `maximize-column` único por workspace; upstream `is_full_width` por columna (varias a la vez)
- [x] **LAY-6** 🟠 DONE 2026-07-23 (ColumnWidth enum {proportion, fixed} portado de scrolling.rs:236-242: resolve_column_width [4401-4411], set_column_width match por match [4851-4909] incl. adjust-proportion-desde-fixed, presets comparados en px con margen de 1px [4820-4838], interactive resize/mod-drag guarda Fixed [3589-3590], expand-column guarda Fixed [2812], flotante->tiled Fixed a su ancho, default natural = Fixed del ancho de la ventana [workspace.rs:890]; verificado en vivo: fixed 800px sobrevive gaps 10->24 intacto mientras la proporcional re-resuelve 720->699, y 800px +10% = 946px exacto) — No existe `ColumnWidth::Fixed`: px degradados a proporción, derivan al cambiar monitor/gap
- [x] **LAY-7** 🟠 DONE 2026-07-23 (ambos sitios delegan en `ColumnLayoutEngine.presetIndex`, que ya era fiel: atrás = último estrictamente menor; check del caso exacto del audit en selftest) — semilla hacia atrás rota
- [x] **LAY-8** 🟠 DONE 2026-07-23 (presetHeightIndex = WindowHeight::Preset(idx), re-resuelto en cada pase por naiveHeights/probe como scrolling.rs:4533-4547; setFixedHeight lo reemplaza por Fixed; 4 checks puros + verificado en vivo: 591px/291px exactos con wrap de índice) — preset materializado a px re-resoluble; no convierte hermanos a Auto
- [x] **LAY-9** 🟠 DONE 2026-07-23 (herencia en 6 sitios: expel x3, flotante→tiled (ancho flotante actual como proporción, LAY-6 pendiente para Fixed real), move-to-workspace, drop del overview; verificado en vivo discriminante: columna expulsada hereda 866px/60%, no el default 720px/50%) — caían al default 0.5 (caen al default 0.5)
- [x] **LAY-10** 🟡 DONE 2026-07-23 — Acción `set-window-width` ausente
- [x] **LAY-11** 🟡 DONE 2026-07-23 — Default compilado gap = 10 vs 16
- [x] **LAY-12** 🟡 DONE 2026-07-23 (maximizada bypasea el índice: compara contra el ancho real como scrolling.rs:4799-4803; verificado discriminante en vivo: 500 vs 963 del índice viejo) — Maximizada no anula el fast-path del índice de presets
- [x] **LAY-13** 🟡 DONE 2026-07-23 (las 3 ramas: modo centrado→toggle full width, única visible→toggle full width, scroll conservando la leftmost visible; guard is_full_width; verificado en vivo: 968=1450−482 exacto; Fixed real sigue en LAY-6) — `expandColumnToAvailableWidth`: faltan 3 ramas (modo centrado→full-width, única columna→toggle, scroll final); guarda proporción vs Fixed
- [x] **LAY-14** 🟡 DONE 2026-07-23 (guards de scrolling.rs:2241-2243/2278-2281: no-op en modo centrado y con la activa no completamente visible) — `centerVisibleColumns` sin guards (no-op en centrado / columna no visible)
- [x] **LAY-15** 🟡 DONE 2026-07-23 (hovered = columna a la IZQUIERDA del puntero como take_while de scrolling.rs:824-830; un punto en el hueco horizontal disputa gap-de-columna vs gap-de-tile; check del caso exacto del audit) — `insertPosition`: hovered por contención estricta; hueco entre columnas sin disputa gap-vs-tile
- [x] **LAY-16** 🟡 DONE 2026-07-23 (salir de tabbed multi-ventana cancela fullscreen y maximize como scrolling.rs:2192-2196; verificado en vivo: fullscreen dentro de tabbed cancelado al destabbear) — Salir de tabbed no cancela fullscreen/maximized
- [x] **LAY-17** 🟡 DONE 2026-07-23 (resizeTiledEdge/resizeFloatingWindowEdge/asEdgeDeltaPercent eliminados — 9.4KB de semántica inventada; nada en el config del usuario ni en el glue DMS la usaba) — `resize-edge` inventado (semántica "splitter" sin contraparte)

### Input / gestos / animaciones (10)
- [x] **ANI-1** 🔴 DONE 2026-07-23 — Sin tabla de defaults por animación: todo spring 800 (workspace-switch=1000, window-open/close=easing 150ms, etc.); fallback workspace-switch→window-movement inventado
- [x] **ANI-2** 🔴 DONE 2026-07-23 (SwipeTracker portado línea por línea [swipe_tracker.rs: historia 150ms, decel 0.997/ms, timestamps monótonos, projected_end_pos] + las tres máquinas de estado de niri: 3 dedos con axis-lock de 16px [input/mod.rs:3910] -> horizontal = view-offset gesture [1200px/vista, pan 1:1 en vivo, snapping a bordes de columna con clamp primera/última, scrolling.rs:3197-3325] y vertical = workspace-switch [300px/workspace, rubber band {0.5,0.05}, min/max center±1, proyección de velocidad y redondeo, monitor.rs]; 4 dedos = overview [300px, umbral 0.5 proyectado]; el reconocedor discreto 0.18/0.4s eliminado; conversión MT normalizado->px 1000dpi documentada como desviación forzada; deslizamiento visual entre workspaces imposible con ventanas parkeadas [AX] - solo la decisión es continua, el switch se anima normal; 8 selftests a mano del tracker + decisión + snapping; el swipe físico requiere dedos reales - queda a tu verificación) — Gestos continuos de niri (SwipeTracker: 150ms, decel 0.997, eje 16px, 300px/ws, 1200px/vista, inercia, snapping) sustituidos por reconocedor discreto con constantes inventadas (0.18 / 0.4s) — MultitouchSupport NO lo bloquea
- [x] **ANI-3** 🟠 DONE 2026-07-23 (rubber_band.rs portado funcion por funcion: band/derivative/clamp/clampDerivative + constantes upstream WORKSPACE/OVERVIEW {0.5, 0.05} y umbral de interactive-move {1.0, 0.5}; 12 selftests con valores calculados a mano; el cableado a gestos llega con ANI-2/ANI-5, sus consumidores) — `rubber_band.rs` ausente por completo
- [x] **ANI-4** 🟠 DONE 2026-07-23 — cubic-bezier evaluado en t sin resolver x (falta `t_for_x` por bisección)
- [x] **ANI-5** 🟠 DONE 2026-07-23 (mod-drag tiled: hasta 256px de recorrido la ventana solo se inclina hacia el puntero via band(sq_dist/256^2) con {stiffness 1, limit 0.5} [layout/mod.rs:97, 3888-3918], sin insert hint; cruzar el umbral inicia el move real; soltar por debajo = snap back sin drop, como el estado Starting de upstream; flotantes arrancan de inmediato [guard !is_floating]; verificado por build+selftests del band - el drag fisico no es inyectable por IPC) — Interactive move sin umbral 256px ni rubber band de arranque
- [x] **ANI-6** 🟡 DONE 2026-07-23 — Ghost de cierre: escala final 0.85 vs 0.8 upstream
- [x] **ANI-7** 🟡 DONE 2026-07-23 — Parser animaciones: spring incompleto no es error (defaults inventados), sin validación de rangos
- [x] **ANI-8** 🟡 DONE 2026-07-23 — Fallback workspace-switch→window-movement (se cierra junto con ANI-1)
- [x] **ANI-9** 🟡 DONE 2026-07-23 (oscillate() exacto de spring.rs con initial_velocity en los 3 regímenes; settle por Newton para sobreamortiguado (duration()), clamped_duration() portado; pisos 0.05/1e-6 eliminados — solo max(0) como upstream; 7 checks, uno me corrigió la relación clamped>=envelope) — Spring: pisos inventados; settle sobreamortiguado incorrecto (termina antes con ζ>1); falta `initial_velocity`/`clamped_duration`
- [x] **ANI-10** 🟡 DONE 2026-07-23 (acumulador de ticks + cooldown 50ms de input/mod.rs:3204-3231 en la rueda del overview; ease-out-quad/cubic con sus beziers EXACTOS (1/3,2/3,2/3,1)/(1/3,1,2/3,1) en CA, expo con la aproximación estándar documentada) — Overview: rueda sin acumulador v120 ni cooldown 50ms; ease-out-quad/cubic mapeados a `.easeOut` genérico teniendo bezier exacto

### Acciones / navegación / overview / chrome (17)
- [x] **ACT-1** 🔴 DONE 2026-07-23 (clamp a len-1 como monitor.rs:1011-1013, ídem relativo; comentario con cita falsa eliminado; verificado en vivo: focus-workspace 99 con 2 workspaces aterriza en el 2, crea 0) — `focus-workspace N` creaba workspaces (ídem relativo: último → no-op)
- [x] **ACT-2** 🔴 DONE 2026-07-23 — = LAY-1 (SizeChange flotante, confirmado independientemente)
- [x] **ACT-3** 🟠 DONE 2026-07-23 (cae a moveWindowToWorkspace como monitor.rs:961-968, cubre también las variantes up/down; verificado en vivo ida y vuelta) — refusaba con un log
- [x] **ACT-4** 🟠 DONE 2026-07-23 — Columna movida se apendiza al final + roba foco incluso con `focus:false` (upstream: junto a la activa, sin tocar foco)
- [x] **ACT-5** 🟠 DONE 2026-07-23 (focus_directional axial puro de floating.rs:839-877 — sin dominancia de eje ni euclídea; extremes geométricos por origen (879-917); wrapping -or-first/-or-last y focus-window-top/bottom/down-or-top ruteados como workspace.rs:924-1040; verificado en vivo: leftmost, axial, wrap) — algoritmo distinto al de niri
- [x] **ACT-6** 🟠 DONE 2026-07-23 (center flotante exacto + presets flotantes vía toggle_width; verificado en vivo) — no-ops inventados
- [x] **ACT-7** 🟠 DONE 2026-07-23 (clipboard SIEMPRE + disco según write-to-disk; flags show-pointer (defaults true/false como upstream), id, path; pantalla enfocada vía -D; verificado en vivo: archivo 1.7MB + clipboard TIFF) — Screenshot: sin portapapeles (upstream SIEMPRE copia), sin flags `show-pointer`/`path`/`id`, pantalla principal vs enfocada
- [x] **ACT-8** 🟠 DONE 2026-07-23 (el overview queda ABIERTO: sync de selección a foco, acción, rebuild del panel; verificado en vivo con set-column-width bajo overview) — Cualquier acción no-navegación colapsa el overview (upstream lo mantiene abierto)
- [x] **ACT-9** 🟠 DONE 2026-07-23 (rueda anclada al workspace bajo cursor; scroll vertical continuo = recorrido de pila a 300px/ws cuantizado a filas — el panel no tiene cámara vertical continua; focus-workspace-previous = back-and-forth por id; v120/cooldown quedan en ANI-10; rueda/scroll físicos no verificables por IPC, ruta compartida con lo verificado) — Overview scroll: rueda sobre la selección vs workspace bajo cursor; continuo → pan horizontal; `focus-workspace-previous` ≠ "fila arriba"
- [x] **ACT-10** 🟠 DONE 2026-07-23 (lista curada exacta de collect_actions con fallbacks y dedup, título custom del bind gana como entry(), Mod+spawn filtrado, hide-not-bound y skip-at-startup de misc.rs:67-85 parseados y honrados — incl. mostrar al arrancar salvo skip; alpha 0.9; sin robo de foco (verificado: frontmost intacto); Escape observe-only documentado como desviación; 7 checks + verificado a nivel píxel) — Hotkey overlay reinventado: lista todo + roba foco (upstream: ~15 curados, alpha 0.9, sin foco)
- [x] **ACT-11** 🟡 DONE 2026-07-23 (compactWorkspaces + reflow + emit en el acto, como monitor.rs:1242-1343; verificado en vivo: el invariante se restaura inmediatamente) — `move-workspace-up/down`/`to-index` no restauran invariantes en el acto ni relayoutan
- [x] **ACT-12** 🟡 DONE 2026-07-23 (caso especial de monitor.rs:646-653 en compactPlan; 4 checks puros incl. que un nombre bloquea el colapso) — `empty-workspace-above-first` con todo vacío: 2 workspaces vs 1
- [x] **ACT-13** 🟡 DONE 2026-07-23 (= LAY-7)
- [x] **ACT-14** 🟡 DONE 2026-07-23 (pasa a tiling primero, workspace.rs:952-957; verificado en vivo: con flotante activa aterriza en la ventana tiled) — quedaba leyendo a través de la flotante; `focusColumnWrapping` no-op con flotante
- [x] **ACT-15** 🟡 DONE 2026-07-23 (backdrop default = color plano gris 0.15; wallpaper solo con layer-rule place-within-backdrop — el opt-in real de niri, que el config del usuario ya declara; anillo de selección = focus-ring del config sin glow; drop indicator = insert-hint plano rgba(127,200,255,128); 2 checks + overview verificado en vivo) — Overview: backdrop-wallpaper por defecto y anillo de selección con glow inventados (upstream: gris 0.15, sin anillo)
- [x] **ACT-16** 🟡 DONE 2026-07-23 (banner top-center con el texto/padding/border de config_error_notification.rs, 4s de Shown, hide en reload exitoso, gate config-notification{disable-failed} de misc.rs:87-102; verificado a nivel píxel con config roto+restaurado byte a byte, y el gate verificado contra el config real del usuario) — Config-error notification inexistente (solo print en log)
- [x] **ACT-17** 🟡 DONE 2026-07-23 (tab-indicator cubierto por CFG-20; acciones compuestas por IPC-11; id= generalizado con WindowTarget - set/reset-window-height, set-window-width, switch-preset-window-width/height(+back), center-window, consume-or-expel-*, fullscreen-window, toggle-windowed-fullscreen, maximize-window-to-edges, toggle-window-floating, move-window-to-floating/tiling, move-window-to-workspace (window-id), move-floating-window, screenshot-window - actuando SIN mover el foco como upstream (activate = source_tile_was_active, scrolling.rs:1830); nombres de workspaces en reload con el contrato de niri.rs:1446-1466: unname de los removidos, los presentes viajan con su Workspace, los nuevos crean workspace vacio arriba; verificado en vivo: resize/consume/expel por id de ventana no enfocada con foco intacto, workspace test-ws creado arriba y des-nombrado al quitarlo, config restaurado byte-identico) — Ausencias: tab-indicator no configurable/sin fallback de color; acciones `focus-window-or-workspace-*`, `focus-window-in-column`, `focus-*-or-monitor-*`, `move-workspace-to-monitor-*`, `workspace-auto-back-and-forth`, param `id=`; renombrado de workspaces por posición en reload
