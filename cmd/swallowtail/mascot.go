package main

import (
	"strings"

	"github.com/bynine/godot-mcp-go/internal/ui"
)

// The butler, as the banner draws him. Each string is one row of pixels in
// a 24 by 24 grid, classed rather than colored so one grid serves both
// renderers: H hair and outline, S skin, C collar, B bow tie, space for
// nothing. It was downsampled from website/public/brand/swallowtail-butler.png
// (the approved mark) with a box filter and classed by luminance, then the
// mouth and collar wings were set by hand where 24 pixels lose them.
var mascotRows = [24]string{
	"         HHHHHH         ",
	"       HHHHHHHHHH       ",
	"     HHHHHHHHHHHHHH     ",
	"   HHHHHHHHHHHHHHHHH    ",
	"  HHHHHHHHHHHHHHHHHHH   ",
	" HHHHHHHHHHHHHHHHHHHHH  ",
	" HHHHHHHSHHHHHSSHHHHHH  ",
	" HHHHHHSSHHHHSSSHHHHHHH ",
	"HHHHHHSSHHHHSSSSSHHHHHH ",
	"HHHHHSSSHHHSSSSSSSHHHHHH",
	"HHHHHSSHHHSSSSSSSSHHHHH ",
	"HHHHSSHHSSSSSSSSSSSHHHH ",
	"  HHSSHSSSSSSSSSSSSHHH  ",
	" HSHSSSSSSSSSSSSSSSHHSH ",
	" HSHHSSHSSSSSSSHSSSHSSH ",
	"  HHHSSSSSSSSSSSSSSSSH  ",
	"    SSSSSHHHSSSSSSSH    ",
	"    HSSSSSSSSSSSSSS     ",
	"     HHSSSSSSSSSSH      ",
	"       HHBSSSSBHH       ",
	"        HCHSHHCH        ",
	"      HHHSBBBBSHHH      ",
	"     HHHHHBHBBHHHHH     ",
	"      HHHHHHHHHHH       ",
}

// 256-color values per class: hair a dark gray that survives a black
// terminal background, skin the warm paper of the site, collar off-white,
// bow the mulberry accent (#81485f by hue).
var mascotColor = map[byte]int{'H': 237, 'S': 223, 'C': 255, 'B': 132}

// mascotLines renders the grid as 12 lines of half-block cells, each cell
// standing for the pixel above and the pixel below. Styled, a cell is a
// block in the top pixel's color over the bottom pixel's; plain (NO_COLOR,
// a dumb terminal), the top pixel's class picks a texture instead, so the
// silhouette still reads without a single escape.
func mascotLines(p ui.Palette) []string {
	lines := make([]string, 0, len(mascotRows)/2)
	for y := 0; y+1 < len(mascotRows); y += 2 {
		top, bottom := mascotRows[y], mascotRows[y+1]
		var b strings.Builder
		for x := 0; x < len(top); x++ {
			b.WriteString(mascotCell(p, top[x], bottom[x]))
		}
		lines = append(lines, b.String())
	}
	return lines
}

func mascotCell(p ui.Palette, top, bottom byte) string {
	if !p.Enabled() {
		switch top {
		case 'H':
			return "█"
		case 'S':
			return "░"
		case 'C':
			return "▒"
		case 'B':
			return "◆"
		}
		return " "
	}
	switch {
	case top == ' ' && bottom == ' ':
		return " "
	case top == bottom:
		return p.Pixel(mascotColor[top], -1, "█")
	case bottom == ' ':
		return p.Pixel(mascotColor[top], -1, "▀")
	case top == ' ':
		return p.Pixel(mascotColor[bottom], -1, "▄")
	}
	return p.Pixel(mascotColor[top], mascotColor[bottom], "▀")
}

// mascotWidth is the art's width in terminal columns; every line is padded
// to it so the text column beside the art stays aligned.
const mascotWidth = 24
