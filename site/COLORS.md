# Website colors: "Glass"

The palette the owner picked for the Clearlock website (modeled on clay.com's system). The site itself was removed to start again; this is what to build it with.

- **The idea:** bright blue for "clear", lime for action. Cream pages, near-black navy ink, one bold hero color, and a pastel tint for each feature with a deep text tone from the same family.
- **Feel:** playful like Duolingo, never cartoonish.
- **Buttons are chunky:** a solid fill with a darker bottom edge (the `edge` colors), which presses down when clicked.
- **Light and dark mode** follow the visitor's system setting. Check text contrast in both after any change.

## Brand

| Name | Hex | Used for |
| --- | --- | --- |
| Blue | `#2f6feb` | Hero background, links, the "clear" color |
| Blue edge | `#1d56b5` | Blue button edge, pressed state, accent text on light pages |
| Lime | `#eef773` | Primary buttons (Download) and highlights |
| Lime edge | `#b4bd2e` | Lime button edge |
| Ink | `#0e1a33` | Text in light mode; dark bands |
| Paper | `#f4f3f0` | Light page background (warm cream); text in dark mode |
| Surface | `#fefdfb` | Cards on the paper |

## Feature tints

One per feature: a background and the text color to put on it.

| Feature | Light bg | Light text | Dark bg | Dark text |
| --- | --- | --- | --- | --- |
| Blue: hands blocked (the shield) | `#bedffe` | `#001433` | `#12305a` | `#bedffe` |
| Lime: stays awake | `#f3f8b5` | `#102b03` | `#2e3410` | `#f3f8b5` |
| Peach: unlocking | `#fcc9ab` | `#381005` | `#4a2412` | `#fcc9ab` |
| Pink: agents keep working | `#f8b9e4` | `#46022f` | `#4a1636` | `#f8b9e4` |

## Roles

| Role | Light | Dark |
| --- | --- | --- |
| Page background | Paper `#f4f3f0` | `#0b1426` |
| Cards | Surface `#fefdfb` | `#13203b` |
| Text | Ink `#0e1a33` | Paper `#f4f3f0` |
| Muted text | Ink 72% mixed into paper | Paper 70% mixed into `#0b1426` |
| Hairlines | Ink at 12% | Paper at 13% |
| Accent (links, icons) | Blue `#2f6feb` | `#6f9bff` |
| Accent text | Blue edge `#1d56b5` | `#8fb4ff` |
| Hero | Blue `#2f6feb`, white text, lime highlight | Same |
| Dark band | Ink `#0e1a33`, paper text, lime accent | `#13203b`, paper text, lime accent |
| Primary button | Lime, ink text, lime edge | Same |
| Secondary button | White `#ffffff`, ink text, edge `#c7d3ea` | `#1b2a4a`, paper text, edge `#0b1426` |
| Focus ring | Blue | Lime |

## As CSS

```css
:root {
  --brand-blue: #2f6feb;  --brand-blue-edge: #1d56b5;
  --brand-lime: #eef773;  --brand-lime-edge: #b4bd2e;
  --brand-ink: #0e1a33;   --brand-paper: #f4f3f0;   --brand-surface: #fefdfb;

  --tint-blue: #bedffe;   --tint-blue-text: #001433;
  --tint-lime: #f3f8b5;   --tint-lime-text: #102b03;
  --tint-peach: #fcc9ab;  --tint-peach-text: #381005;
  --tint-pink: #f8b9e4;   --tint-pink-text: #46022f;
}

@media (prefers-color-scheme: dark) {
  :root {
    --tint-blue: #12305a;   --tint-blue-text: #bedffe;
    --tint-lime: #2e3410;   --tint-lime-text: #f3f8b5;
    --tint-peach: #4a2412;  --tint-peach-text: #fcc9ab;
    --tint-pink: #4a1636;   --tint-pink-text: #f8b9e4;
  }
}
```

## Not brand colors

Product mock-ups of the Mac app use the app's own macOS colors (its default orange lock tint `#ff9500`, the Touch ID pink `#ff375f`, system window and menu colors), not these.
