Tiles an image on a page for printing in a grid.

Accepts multiple images — each will be printed on its own page.

```
Usage: gridprint.sh [OPTIONS] IMAGE [IMAGE...]

Arguments:
  IMAGE...              (required) one or more source images;
                        each image gets its own page

Options (all optional):
  -f, --format FORMAT   Paper: A4, A5, A3, A2, Letter, Legal, Tabloid [default: A4]
  -g, --grid RxC        Grid R rows x C cols (e.g. 2x3)
  -n, --count N         Total copies per sheet (auto grid)
  -t, --tile WxH        Tile size in mm (e.g. 40x40). Image is fitted inside
                        and tiled; grid is centered on the page.
                        Mutually exclusive with -g and -n.
  -o, --output FILE     Output PDF [default: stdout]
  -c, --cuts            Draw light thin cutting crosses and edge ticks
  -m, --mirror [AXIS]   Mirror: x (default), y, or xy
                        -m       -> mirror horizontally
                        -m x     -> same
                        -m y     -> mirror vertically
                        -m xy    -> mirror both axes
  -h, --help            Show help
```
