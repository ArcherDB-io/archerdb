package main

import (
	"bufio"
	"flag"
	"fmt"
	"os"
	"strconv"
	"strings"

	"github.com/golang/geo/s2"
)

func main() {
	var inPath string
	var outPath string
	flag.StringVar(&inPath, "in", "", "Input TSV path (lat_nano\\tlon_nano\\tlevel)")
	flag.StringVar(&outPath, "out", "", "Output TSV path (lat_nano\\tlon_nano\\tlevel\\tcell_id_hex)")
	flag.Parse()

	if inPath == "" || outPath == "" {
		fmt.Fprintln(os.Stderr, "usage: go_s2_ref --in <path> --out <path>")
		os.Exit(2)
	}

	inF, err := os.Open(inPath)
	if err != nil {
		fmt.Fprintf(os.Stderr, "open input: %v\n", err)
		os.Exit(1)
	}
	defer inF.Close()

	outF, err := os.Create(outPath)
	if err != nil {
		fmt.Fprintf(os.Stderr, "create output: %v\n", err)
		os.Exit(1)
	}
	defer outF.Close()

	in := bufio.NewScanner(inF)
	in.Buffer(make([]byte, 0, 64*1024), 256*1024)

	out := bufio.NewWriterSize(outF, 256*1024)
	defer func() { _ = out.Flush() }()

	lineNo := 0
	for in.Scan() {
		lineNo++
		line := strings.TrimSpace(in.Text())
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		if strings.HasPrefix(line, "lat_nano") {
			continue
		}

		fields := strings.Split(line, "\t")
		if len(fields) != 3 {
			fmt.Fprintf(os.Stderr, "invalid input (line %d): expected 3 TSV fields, got %d\n", lineNo, len(fields))
			os.Exit(1)
		}

		latNano, err := strconv.ParseInt(fields[0], 10, 64)
		if err != nil {
			fmt.Fprintf(os.Stderr, "invalid lat_nano (line %d): %v\n", lineNo, err)
			os.Exit(1)
		}
		lonNano, err := strconv.ParseInt(fields[1], 10, 64)
		if err != nil {
			fmt.Fprintf(os.Stderr, "invalid lon_nano (line %d): %v\n", lineNo, err)
			os.Exit(1)
		}
		levelU64, err := strconv.ParseUint(fields[2], 10, 8)
		if err != nil {
			fmt.Fprintf(os.Stderr, "invalid level (line %d): %v\n", lineNo, err)
			os.Exit(1)
		}
		level := int(levelU64)
		if level < 0 || level > 30 {
			fmt.Fprintf(os.Stderr, "invalid level (line %d): %d (expected 0..30)\n", lineNo, level)
			os.Exit(1)
		}

		latDeg := float64(latNano) / 1_000_000_000.0
		lonDeg := float64(lonNano) / 1_000_000_000.0

		ll := s2.LatLngFromDegrees(latDeg, lonDeg).Normalized()
		cid := s2.CellIDFromLatLng(ll).Parent(level)

		_, _ = fmt.Fprintf(out, "%d\t%d\t%d\t0x%016x\n", latNano, lonNano, level, uint64(cid))
	}

	if err := in.Err(); err != nil {
		fmt.Fprintf(os.Stderr, "scan input: %v\n", err)
		os.Exit(1)
	}
}

