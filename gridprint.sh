#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
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
EOF
  exit "${1:-1}"
}

if (( $# == 0 )); then
  usage 0
fi

FORMAT=A4; GRID=""; COUNT=""; TILE_SPEC=""; OUTPUT=""; CUTS=0; MIRROR=""
IMAGES=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    -f|--format) FORMAT="$2"; shift 2 ;;
    -g|--grid)   GRID="$2";   shift 2 ;;
    -n|--count)  COUNT="$2";  shift 2 ;;
    -t|--tile)   TILE_SPEC="$2"; shift 2 ;;
    -o|--output) OUTPUT="$2"; shift 2 ;;
    -c|--cuts)   CUTS=1; shift ;;
    -m|--mirror)
      if [[ $# -ge 2 && "$2" =~ ^(x|y|xy)$ ]]; then
        MIRROR="$2"; shift 2
      else
        MIRROR="x"; shift
      fi
      ;;
    --mirror=*)
      val="${1#*=}"
      if [[ ! "$val" =~ ^(x|y|xy)$ ]]; then
        echo "Error: --mirror expects x, y, or xy (got '$val')" >&2; exit 1
      fi
      MIRROR="$val"; shift
      ;;
    -h|--help)   usage 0 ;;
    --) shift; while [[ $# -gt 0 ]]; do IMAGES+=("$1"); shift; done; break ;;
    -*) echo "Error: unknown option: $1" >&2; usage 1 ;;
    *)  IMAGES+=("$1"); shift ;;
  esac
done

(( ${#IMAGES[@]} > 0 )) || { echo "Error: missing IMAGE" >&2; usage 1; }
for img in "${IMAGES[@]}"; do
  [[ -f "$img" ]] || { echo "Error: file not found: $img" >&2; exit 1; }
done

sel=0
[[ -n "$GRID" ]]      && sel=$((sel+1))
[[ -n "$COUNT" ]]     && sel=$((sel+1))
[[ -n "$TILE_SPEC" ]] && sel=$((sel+1))
(( sel <= 1 )) || { echo "Error: --grid, --count and --tile are mutually exclusive" >&2; exit 1; }

if [[ -n "$TILE_SPEC" ]]; then
  if [[ ! "$TILE_SPEC" =~ ^[0-9]+(\.[0-9]+)?x[0-9]+(\.[0-9]+)?$ ]]; then
    echo "Error: bad tile '$TILE_SPEC' (expected WxH in mm, e.g. 40x40)" >&2; exit 1
  fi
  TILE_W_MM="${TILE_SPEC%x*}"
  TILE_H_MM="${TILE_SPEC#*x}"
fi

if command -v magick >/dev/null 2>&1; then
  IM=(magick); IDENTIFY=(magick identify)
elif command -v convert >/dev/null 2>&1; then
  IM=(convert); IDENTIFY=(identify)
else
  echo "Error: ImageMagick not found" >&2; exit 1
fi

DPI=300
case "${FORMAT^^}" in
  A4)      PW=2480; PH=3508 ;;
  A5)      PW=1748; PH=2480 ;;
  A3)      PW=3508; PH=4961 ;;
  A2)      PW=4961; PH=7016 ;;
  LETTER)  PW=2550; PH=3300 ;;
  LEGAL)   PW=2550; PH=4200 ;;
  TABLOID) PW=3300; PH=5100 ;;
  *) echo "Error: unknown paper format '$FORMAT'" >&2; exit 1 ;;
esac

if [[ -n "$TILE_SPEC" ]]; then
  TILE_W_PX=$(awk -v w="$TILE_W_MM" -v d="$DPI" 'BEGIN{printf "%d", w*d/25.4 + 0.5}')
  TILE_H_PX=$(awk -v h="$TILE_H_MM" -v d="$DPI" 'BEGIN{printf "%d", h*d/25.4 + 0.5}')
  (( TILE_W_PX >= 1 && TILE_H_PX >= 1 )) || { echo "Error: tile too small" >&2; exit 1; }
fi

if [[ -n "$GRID" ]]; then
  R="${GRID%x*}"; C="${GRID#*x}"
  [[ "$R" =~ ^[0-9]+$ && "$C" =~ ^[0-9]+$ ]] && (( R>0 && C>0 )) \
    || { echo "Error: bad grid '$GRID'" >&2; exit 1; }
fi

TMPDIR_RUN=$(mktemp -d)
trap 'rm -rf "$TMPDIR_RUN"' EXIT

PAGE_FILES=()
PAGE_IDX=0

for SRC in "${IMAGES[@]}"; do
  if ! dims=$("${IDENTIFY[@]}" -format "%w %h\n" "$SRC" 2>&1); then
    echo "Error: identify failed for '$SRC':" >&2
    echo "$dims" >&2
    exit 1
  fi
  read -r IMG_W IMG_H <<< "$dims"
  [[ "$IMG_W" =~ ^[0-9]+$ && "$IMG_H" =~ ^[0-9]+$ ]] && (( IMG_W>0 && IMG_H>0 )) \
    || { echo "Error: bad dimensions for '$SRC': '$dims'" >&2; exit 1; }

  if [[ -n "$TILE_SPEC" ]]; then
    CELL_W="$TILE_W_PX"; CELL_H="$TILE_H_PX"
    C_cur=$((PW / CELL_W)); R_cur=$((PH / CELL_H))
    if (( C_cur < 1 || R_cur < 1 )); then
      echo "Error: tile ${TILE_W_MM}x${TILE_H_MM}mm larger than page" >&2
      exit 1
    fi
    OFF_X=$(( (PW - C_cur*CELL_W) / 2 ))
    OFF_Y=$(( (PH - R_cur*CELL_H) / 2 ))
  elif [[ -n "$COUNT" ]]; then
    [[ "$COUNT" =~ ^[0-9]+$ ]] && (( COUNT>0 )) || { echo "Error: bad count" >&2; exit 1; }
    best_r=1; best_c="$COUNT"; best_s=0
    for ((r=1; r*r<=COUNT; r++)); do
      (( COUNT % r == 0 )) || continue
      c=$((COUNT/r))
      for pair in "$r $c" "$c $r"; do
        read -r rr cc <<< "$pair"
        cw_try=$((PW/cc)); ch_try=$((PH/rr))
        s=$(awk -v cw="$cw_try" -v ch="$ch_try" -v iw="$IMG_W" -v ih="$IMG_H" \
            'BEGIN{a=cw/iw;b=ch/ih;print (a<b)?a:b}')
        if awk -v s="$s" -v bs="$best_s" 'BEGIN{exit !(s>bs)}'; then
          best_s="$s"; best_r="$rr"; best_c="$cc"
        fi
      done
    done
    R_cur="$best_r"; C_cur="$best_c"
    CELL_W=$((PW/C_cur)); CELL_H=$((PH/R_cur))
    OFF_X=0; OFF_Y=0
  elif [[ -n "$GRID" ]]; then
    R_cur="$R"; C_cur="$C"
    CELL_W=$((PW/C_cur)); CELL_H=$((PH/R_cur))
    OFF_X=0; OFF_Y=0
  else
    R_cur=1; C_cur=1
    CELL_W="$PW"; CELL_H="$PH"
    OFF_X=0; OFF_Y=0
  fi

  sW=$(awk -v cw="$CELL_W" -v ch="$CELL_H" -v iw="$IMG_W" -v ih="$IMG_H" \
       'BEGIN{a=cw/iw;b=ch/ih;s=(a<b)?a:b;printf "%d",iw*s}')
  sH=$(awk -v cw="$CELL_W" -v ch="$CELL_H" -v iw="$IMG_W" -v ih="$IMG_H" \
       'BEGIN{a=cw/iw;b=ch/ih;s=(a<b)?a:b;printf "%d",ih*s}')
  (( sW<1 )) && sW=1
  (( sH<1 )) && sH=1

  PAGE_IDX=$((PAGE_IDX+1))
  TMP_IMG="$TMPDIR_RUN/img_${PAGE_IDX}.png"
  TMP_PAGE="$TMPDIR_RUN/page_${PAGE_IDX}.png"

  resize_args=( "$SRC" -colorspace sRGB -depth 8 )
  case "$MIRROR" in
    x)  resize_args+=( -flop ) ;;
    y)  resize_args+=( -flip ) ;;
    xy) resize_args+=( -flip -flop ) ;;
    "") : ;;
  esac
  resize_args+=( -resize "${sW}x${sH}!" "$TMP_IMG" )

  "${IM[@]}" "${resize_args[@]}" \
    || { echo "Error: resize failed for '$SRC'" >&2; exit 1; }

  cmd=( "${IM[@]}" -size "${PW}x${PH}" xc:white -colorspace sRGB -depth 8 )
  for ((row=0; row<R_cur; row++)); do
    for ((col=0; col<C_cur; col++)); do
      x=$(( OFF_X + col*CELL_W + (CELL_W-sW)/2 ))
      y=$(( OFF_Y + row*CELL_H + (CELL_H-sH)/2 ))
      cmd+=( "$TMP_IMG" -geometry "+${x}+${y}" -composite )
    done
  done

  if (( CUTS )); then
    half=$(( 5*DPI/25 )); (( half<3 )) && half=3
    arm=$(( 6*DPI/25 ));  (( arm<3 ))  && arm=3

    cmd+=( -stroke '#c0c0c0' -strokewidth 2 -fill none )

    for ((i=0; i<=R_cur; i++)); do
      for ((j=0; j<=C_cur; j++)); do
        cx=$(( OFF_X + j*CELL_W )); cy=$(( OFF_Y + i*CELL_H ))
        cmd+=( -draw "line $((cx-half)),${cy} $((cx+half)),${cy}" \
               -draw "line ${cx},$((cy-half)) ${cx},$((cy+half))" )
      done
    done

    top_end=$(( OFF_Y + arm ))
    bot_start=$(( PH - OFF_Y - arm ))
    (( top_end > PH )) && top_end=$PH
    (( bot_start < 0 )) && bot_start=0
    for ((j=1; j<C_cur; j++)); do
      x=$(( OFF_X + j*CELL_W ))
      cmd+=( -draw "line ${x},0 ${x},${top_end}" \
             -draw "line ${x},${bot_start} ${x},${PH}" )
    done

    left_end=$(( OFF_X + arm ))
    right_start=$(( PW - OFF_X - arm ))
    (( left_end > PW )) && left_end=$PW
    (( right_start < 0 )) && right_start=0
    for ((i=1; i<R_cur; i++)); do
      y=$(( OFF_Y + i*CELL_H ))
      cmd+=( -draw "line 0,${y} ${left_end},${y}" \
             -draw "line ${right_start},${y} ${PW},${y}" )
    done
  fi

  cmd+=( -units PixelsPerInch -density "$DPI" "$TMP_PAGE" )
  "${cmd[@]}" || { echo "Error: compose failed for '$SRC'" >&2; exit 1; }

  PAGE_FILES+=("$TMP_PAGE")
done

TMP_PDF="$TMPDIR_RUN/out.pdf"
TMP_PS="$TMPDIR_RUN/out.ps"

make_pdf() {
  # 1) img2pdf — best: lossless, keeps exact page size
  if command -v img2pdf >/dev/null 2>&1; then
    if img2pdf --dpi "$DPI" -o "$TMP_PDF" "${PAGE_FILES[@]}" 2>/dev/null \
         && [[ -s "$TMP_PDF" ]]; then
      return 0
    fi
  fi

  # 2) ImageMagick -> PDF directly (may be blocked by policy)
  if "${IM[@]}" "${PAGE_FILES[@]}" -units PixelsPerInch -density "$DPI" "$TMP_PDF" 2>/dev/null \
       && [[ -s "$TMP_PDF" ]]; then
    return 0
  fi

  # 3) ImageMagick -> PS, then Ghostscript (ps2pdf or gs) -> PDF
  if "${IM[@]}" "${PAGE_FILES[@]}" -units PixelsPerInch -density "$DPI" "$TMP_PS" 2>/dev/null \
       && [[ -s "$TMP_PS" ]]; then
    if command -v ps2pdf >/dev/null 2>&1; then
      if ps2pdf "$TMP_PS" "$TMP_PDF" 2>/dev/null && [[ -s "$TMP_PDF" ]]; then
        return 0
      fi
    fi
    if command -v gs >/dev/null 2>&1; then
      if gs -q -dNOPAUSE -dBATCH -sDEVICE=pdfwrite -sOutputFile="$TMP_PDF" "$TMP_PS" 2>/dev/null \
           && [[ -s "$TMP_PDF" ]]; then
        return 0
      fi
    fi
  fi

  return 1
}

make_pdf || {
  echo "Error: no PDF backend worked." >&2
  echo "  Tried: img2pdf, ImageMagick->PDF, ImageMagick->PS->Ghostscript." >&2
  echo "  Install one of:" >&2
  echo "    Debian/Ubuntu: sudo apt install img2pdf   (recommended)" >&2
  echo "                   sudo apt install ghostscript" >&2
  echo "    Fedora:        sudo dnf install img2pdf ghostscript" >&2
  echo "    Arch:          sudo pacman -S img2pdf ghostscript" >&2
  exit 1
}

if [[ -n "$OUTPUT" ]]; then
  cp -f "$TMP_PDF" "$OUTPUT"
else
  cat "$TMP_PDF"
fi
