# NeuroBit64-Pancreas: a 1000-cell islet network chip: 594 beta, 313 alpha and 93 delta cells, each with an adrenergic neuron

A variant of [NeuroBit64](https://github.com/asifnazquaidian/neurobit64) for the pancreas. **Design and simulation only: no chip has been fabricated and there is no mask layout (GDSII) for this chip.**

It belongs to a family of three organ chips that share one architecture, one brain link and one telemetry format:
[NeuroBit64-Cardio](https://github.com/asifnazquaidian/neurobit64-cardio), [NeuroBit64-Pancreas](https://github.com/asifnazquaidian/neurobit64-pancreas), [NeuroBit64-Kidney](https://github.com/asifnazquaidian/neurobit64-kidney).

| Item | Value |
|---|---|
| Network | 594 beta cells + 313 alpha cells + 93 delta cells, and 1000 adrenergic neurons (alpha-2 type on beta and delta cells, beta-2 type on alpha cells) |
| Architecture | one cell circuit shared by all units, one unit per slot of 8 clocks (as in NeuroBit64-S), 1000 slots per tick |
| Clock | 8 MHz gives 1 tick = 1 ms, i.e. the model runs in real time |
| State | `{ne[6:0], u[15:0], v[11:0]}` = 35 bits per cell, held in a circulating shift register |
| Brain link | 3 wires to a NeuroBit64-S chip: `nb_sdi` (32 group-activity bytes and their inverted copies, one sample per neuron), `nb_sdo` and `nb_sync` (its 64 decision bits; neurons 0-31 are counted as sympathetic, 32-63 as parasympathetic drive) |
| Telemetry | UART, 115.9 kbaud, one 19-byte frame every 16 ms, for a Bluetooth serial module or a USB cable; and the bit stream of a Bluetooth LE advertising packet every 128 ms for a 2.4 GHz transmitter |
| Raster output | `sdo`, `sck`, `sync`: one event bit per unit per tick in the NeuroBit64-S serial format (1 Mbit/s at 8 MHz) |
| Size (SkyWater 130 nm, Yosys) | about 140,446 standard cells, 34,040 flip-flops, 1.27 mm2 of cell area (synthesised); die about 1.9 x 1.9 mm with 24 pads |

```
                 nb_sdi                       uart_tx  --> Bluetooth serial module --> phone / PC
 NeuroBit64-S  <--------  NeuroBit64-Pancreas  bb_data  --> 2.4 GHz GFSK transmitter (not designed)
 (brain chip)  -------->  1000 units            sdo/sck/sync --> serial memory (raster)
              nb_sdo, nb_sync
```

## The model

- Cell: the HEC model for pancreatic alpha, beta and delta cells of the thesis (section "Pancreatic Cells" and its parameter table; the same interpretation of the table as in the GlucoSense GS-1 chip): `v' = v + k f (v - Vr)(v - Vt)/C - u/C + (Va + Vb)/C + I`, `u' = u + a (b (v - Vr) - u)`, spike when `v >= Vt + Va + Vb`, then `v = c`, `u = u + d`.
- `Va = Vglu x glucagon level` and `Vb = Vins x insulin level`. The two levels are produced by the cells themselves: every alpha-cell spike adds glucagon (decay 256 ms, the thesis value Tk = 250 ms), every beta- or delta-cell spike adds insulin (a bell-shaped pulse made by two 32 ms stages).
- Glucose drives the alpha cells below 90 mg/dL and the beta and delta cells above 100 mg/dL; below 100 mg/dL it holds the beta and delta cells down (K-ATP-like term). Beta cells are coupled to the neighbouring beta cells.
- Neurons: every cell has one adrenergic neuron (NeuroBit64 leaky integrate-and-fire rule) driven by the sympathetic signal. A spike of an alpha-2 neuron pushes its beta or delta cell down; a spike of a beta-2 neuron pushes its alpha cell up. The parasympathetic signal adds drive to the beta cells.
- Read-out: the chip reads the glucose level back from the firing rates (beta rate when the beta cells are active, alpha rate otherwise). The two straight-line calibrations were fitted on the healthy islet of this model.

### What was added to the thesis model

- The thesis gives the cell equations and the parameter table; it has no network and no glucose input. The glucose drive, the hormone fields made by the population, the coupling, the adrenergic neurons, the read-out and the eight conditions are design decisions of this chip and are not validated against islet recordings.
- With the thesis constants (b = -5, k f = 0.15, C = 100) a beta cell is active without any input; the hold-down term below 100 mg/dL was added so that beta cells are silent at low glucose.

## What the chip reports

Every 16 ticks: sequence number, organ and condition, flags, mean membrane potential, beta, alpha and delta spikes, glucose given to the chip (mg/dL), glucose read back from the cells (mg/dL), insulin level, brain drive.

Flags: low glucose (read value < 70 mg/dL), high glucose (> 180), beta cells do not answer (glucose in > 140 but read value < 110), alpha cells do not answer (glucose in < 70 but read value > 80), strong sympathetic drive.

Conditions (pins `cond[2:0]`, for demonstration and test): 0 healthy islet with a glucose sweep 40-295 mg/dL, 1-3 healthy islet at 50, 95, 240 mg/dL, 4 loss of 13/16 of the beta cells, 5 weak beta-cell response, 6 no alpha-cell response, 7 high sympathetic tone.

Input: the glucose value can be written through `uart_rx` (bytes `47 lo hi`, mg/dL), for example by the phone app or by a GlucoSense sensor node; `47 FF FF` returns to the built-in value.

Results of the software model (`design/results/model_summary.txt`):

```
NeuroBit64-Pancreas, software model

A. Healthy islet at fixed glucose (8 s each; rates over the last 4 s)

glucose in   beta Hz  alpha Hz  delta Hz  insulin %  glucose read  error
     40          0      53.7         0         0           41      1
     50          0      44.5         0         0           49     -1
     60          0      33.7         0         0           59     -1
     70          0      23.9         0         0           69     -1
     80          0      12.1         0         0           81      1
     90          0       0.5         0         0           90      0
    100       28.7       0.5       3.5        26           90    -10
    120       37.2       0.5       7.9        35          123      3
    140       44.1       0.5      14.1        42          150     10
    160       50.1       0.5      18.3        48          170     10
    180       56.8       0.5      23.1        55          196     16
    200       60.4       0.5      25.7        59          209      9
    240       69.1       0.5      32.2        68          247      7
    280       76.9       0.5      38.1        76          274     -6

B. All conditions, 32.8 s of model time (two glucose sweeps where the glucose is swept)

cond  condition                                  brain chip  mean |read - in|  max   flags raised (% of reports)
0     healthy islet, glucose sweep               none                 8        54   low glucose 11, high glucose 51
1     healthy islet, low glucose (50 mg/dL)      none               0.6         2   low glucose 100
2     healthy islet, normal glucose (95 mg/dL)   none                 5         5   none
3     healthy islet, high glucose (240 mg/dL)    none               6.9         8   high glucose 100
4     beta-cell loss, glucose sweep              none                99       204   low glucose 38, beta cells do not answer 63
5     weak beta-cell response, glucose sweep     none              61.5       131   low glucose 13, beta cells do not answer 20
6     no alpha-cell response, glucose sweep      none              11.8        55   low glucose 2, high glucose 51, alpha cells do not answer 9
7     high sympathetic tone, glucose sweep       none              51.2       127   low glucose 17, high glucose 24, beta cells do not answer 15, strong sympathetic drive 100
0     healthy islet, glucose sweep               connected            8        54   low glucose 11, high glucose 51
1     healthy islet, low glucose (50 mg/dL)      connected          0.6         2   low glucose 100
2     healthy islet, normal glucose (95 mg/dL)   connected            5         5   none
3     healthy islet, high glucose (240 mg/dL)    connected          6.9         8   high glucose 100
4     beta-cell loss, glucose sweep              connected           99       204   low glucose 38, beta cells do not answer 63
5     weak beta-cell response, glucose sweep     connected         61.5       131   low glucose 13, beta cells do not answer 20
6     no alpha-cell response, glucose sweep      connected         11.8        55   low glucose 2, high glucose 51, alpha cells do not answer 9
7     high sympathetic tone, glucose sweep       connected         67.5       147   low glucose 54, high glucose 14, beta cells do not answer 23, strong sympathetic drive 100
```

## Verification

The Verilog was simulated with Icarus Verilog and compared with the software model `design/model/nb64_pancreas_model.js`, which uses the same integer arithmetic. Compared: every UART frame, every Bluetooth LE advertising packet bit by bit, the number of events and a 64-bit signature of the whole raster stream and, with a NeuroBit64-S chip (its real Verilog) wired to the link, the word count and signature of that chip. An independent receiver model also checked the CRC of every advertising packet.

| Condition | Ticks (ms) | NeuroBit64-S connected | Frames | BLE packets | Raster events | Brain words | Result |
|---|---|---|---|---|---|---|---|
| 0 (input 230 written through uart_rx in tick 40) | 1600 | yes | 100 | 36 | 67283 | 24998 | identical |
| 4 | 960 | no | 60 | 21 | 20650 | - | identical |
| 7 | 960 | yes | 60 | 21 | 18304 | 14998 | identical |
| 1 | 480 | no | 30 | 9 | 6880 | - | identical |
| 3 | 480 | no | 30 | 9 | 22023 | - | identical |
| 5 | 640 | no | 40 | 15 | 9035 | - | identical |
| 6 | 640 | yes | 40 | 15 | 118 | 9998 | identical |

Full record: `design/results/verilog_vs_model.txt`. Icarus Verilog needs about 0.25 s per tick for 1000 units, so the long runs (60 s of model time) were made with the software model only.

## Size

| Units | Standard cells | Flip-flops | Cell area (um2) | |
|---|---|---|---|---|
| 64 | 16906 | 3150 | 148401 | synthesised |
| 128 | 25337 | 5262 | 225113 | synthesised |
| 1000 | 140446 | 34040 | 1273279 | synthesised (straight-line estimate from the two rows above: 140209 cells, 1270319 um2) |

About 1199 um2 per unit and 71689 um2 for everything else. `design/floorplan.svg` is a to-scale block floorplan (a planning drawing). The chip is larger than the biggest Tiny Tapeout tile (8x2 tiles, about 0.3 mm2), so it needs its own die on an open multi-project wafer run.

## What has NOT been done

- **No layout.** Place and route, timing analysis and gate-level simulation have not been run. 8 MHz is slow for 130 nm, but that is an expectation, not a result.
- **No radio.** The chip makes the bits of the advertising packet; the 2.4 GHz transmitter is analog and is not designed. The practical route to a phone is the UART pin with a ready-made Bluetooth serial module, and that path has not been tried with hardware.
- **The link was simulated only with both chips released from reset together.** The logic that re-aligns to the `sync` pin of NeuroBit64-S after a different start has not been exercised.
- **The meaning of the brain link is a convention of these chips** (which NeuroBit64 neurons count as sympathetic or parasympathetic). NeuroBit64-S is a general 64-neuron chip, not a model of a brain region.
- The glucose value is an input of the chip (from a sensor such as GlucoSense GS-1, or the built-in sweep). The chip does not measure glucose; it shows how the islet model answers to it and whether that answer is the expected one.

## Files

| Path | Content |
|---|---|
| `design/rtl/nb64_pancreas.v` | the chip |
| `design/rtl/nb64_link.v`, `design/rtl/nb64_telemetry.v` | brain link, UART and Bluetooth LE packet generator (shared by the three chips) |
| `design/tb/` | test bench and the NeuroBit64-S chip used in the link tests |
| `design/model/` | software model (`nb64_pancreas_model.js`, `nb64_common.js`), test and summary scripts |
| `design/results/` | test records, model summary, synthesis reports |
| `design/synth/` | Yosys scripts |
| `app/` | NeuroBit64 Organ Monitor (web app) |

## Repeat the tests

Needs Node.js, Icarus Verilog and (for the size) Yosys with the sky130 liberty file.

```
pwsh design/run_tests.ps1 -Organ pancreas -Tests "0,320,0;1,320,1"     # condition,ticks,link ; ...
node design/model/summary.js
```

## Monitor app

Online: https://asifnazquaidian.github.io/neurobit64-pancreas/app/?organ=pancreas (the simulated chip starts when the page opens; add `&cond=1` to choose a condition, `&link=1` to connect the brain chip, `&run=0` to open it stopped).

Or open `app/index.html` from this folder. It runs the chip model in the browser, or receives the frames from a Bluetooth serial module (Web Bluetooth) or a serial port (Web Serial) and shows the readings, the flags and the signals. It was tested with the simulated source only.

## Reference and licence

A. Mehmood, "Artificial Neuron Model for Large Scale Spiking Brain Neural Network", PhD thesis, University of Engineering and Technology Taxila, 2025.

Copyright (c) 2026 Asif Mehmood. Apache License 2.0 (see `LICENSE`). AI tools were used where applicable, for convenience, in preparing the circuit description, the tests and this document. This is a research design, not a medical device.
