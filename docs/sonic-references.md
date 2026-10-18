# Sonic wallpaper: references and notes

Where we are: Sonic is a ring of real macOS Liquid Glass that swells with whatever the Mac plays,
with glass drops that melt in and split off, over drifting colored light.

Add your notes under each reference, then we pick a direction at the bottom.

---

## 1. Opera Sonic (the original)
https://press.opera.com/2025/11/14/opera-spotify-sonic-music-theme/

- What it actually is: **not liquid**. It's meant to look like *sound waves moving a thin layer of sand*
  (cymatics). When music starts, the pattern **breaks into fine particles** that dance.
- How it works: audio is turned into a **power spectrum texture** (one axis frequency, one axis time),
  a shader samples it per pixel, applies a **frequency compensation curve** so bass doesn't drown
  the highs, and the result drives motion **and color**.
- Dark mode only; colors are customizable (vivid palettes vs. monochrome grays).
- Only runs on the Start page and pauses during calls/video to save power.

Take from it:
- Spectrum **history over time** (not just "now") gives that smeared, flowing trail.
- Particles that scatter on loud moments and settle into the shape when it's quiet.
- Pause when not visible (we already only animate the start page).

Your notes:
-

---

## 2. Liquid Glass Studio (most complete web recreation)
https://liquid-glass-studio.vercel.app · source: https://github.com/iyinchao/liquid-glass-studio

- Sliders for refraction, **dispersion** (rainbow fringes), **Fresnel** (bright rim at glancing edges),
  glare, blur, and **shape-merging blobs**.

Take from it:
- Play with the sliders to find the exact "glass" feel you want; those numbers map to our ring.
- Dispersion + Fresnel rim are the two things our glass is missing most.

Your notes:
-

---

## 3. LiquidGlass by ybouane (WebGL)
https://liquid-glass.ybouane.com

- Thick glass slabs over a photo/video: strong **edge refraction** and visible **chromatic aberration**
  (red/blue split) right at the edges, clear in the middle.

Take from it:
- Glass reads as glass when the **edges bend hard and the middle stays clear**.
- A busy, detailed background behind the glass sells the refraction; a flat dark background hides it.

Your notes:
-

---

## 4. Metaballs / liquid blobs
https://21st.dev/@paper-design/components/metaballs.md (and Ink Drops / Solar variants)

- Signed-distance metaballs that move, merge and split; the "Ink Drops" variant is very liquid.

Take from it:
- How blobs **stretch into a neck** before they split (ours just pop apart).

Your notes:
-

---

## 5. Apple Intelligence / Siri edge glow
- Usually rebuilt as a rotating angular-gradient stroke, blurred and layered for bloom.
  Apple's own effect isn't a public API.

Take from it:
- Our tab loading shimmer is already this idea; could reuse it as an "AI is thinking" glow.

Your notes:
-

---

## 6. Cymatics / Chladni plates (physics behind Opera's look)
https://us.kef.com/blogs/news/cymatics-the-visualization-of-sound

- Sand collects where vibration cancels out; **higher frequency → more intricate patterns**.

Take from it:
- Pitch could pick the pattern's complexity, loudness its intensity.

Your notes:
-

---

## Direction (pick one or mix)

- [ ] **A. Sand / particles like Opera**: thousands of glowing particles forming cymatic patterns that scatter on beats.
- [ ] **B. Push the glass further**: add dispersion fringes, a Fresnel rim, necking drops, and a more detailed light field behind it to refract.
- [ ] **C. Both**: glass ring with particles inside it that dance to the music.
- [ ] Other:
