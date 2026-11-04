#!/usr/bin/env python3
"""Probe a Redragon SS552 (0200:3001, Mirabox N4 family) over Linux hidraw.

Paints every screen slot with its wire number, then logs raw input reports
(key presses, knob turns, touch strip) until Ctrl-C. Used to confirm the
protocol and the slot layout before writing the Swift driver.

Protocol from github.com/4ndv/mirajazz (protocol v3): 1024-byte output
reports, commands are "CRT\\0\\0" + ASCII verb; images are JPEG, rotated 180.

usage: ss552_probe.py [/dev/hidrawN] [--seconds N]
"""
import glob, os, select, sys, time
from io import BytesIO
from PIL import Image, ImageDraw, ImageFont

PACKET = 1024
CRT = b"CRT\x00\x00"


def find_device():
    for d in glob.glob("/sys/class/hidraw/hidraw*"):
        uevent = open(f"{d}/device/uevent").read()
        desc = open(f"{d}/device/report_descriptor", "rb").read()
        # vendor usage page 0xFFA0 is the deck interface (the other one is a keyboard)
        if "00000200:00003001" in uevent and desc.startswith(b"\x06\xa0\xff"):
            return "/dev/" + os.path.basename(d)
    sys.exit("SS552 not found")


def send(fd, payload: bytes):
    # leading 0x00 = report id (none); hidraw strips it
    assert len(payload) <= PACKET
    os.write(fd, b"\x00" + payload.ljust(PACKET, b"\x00"))


def cmd(fd, verb: bytes, *args: int):
    send(fd, CRT + verb + bytes(args))


def jpeg(label: str, size, color) -> bytes:
    img = Image.new("RGB", size, color)
    d = ImageDraw.Draw(img)
    font = ImageFont.truetype("/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf", 44)
    d.text((size[0] / 2, size[1] / 2), label, fill="white", font=font, anchor="mm")
    d.rectangle([0, 0, size[0] - 1, size[1] - 1], outline="white", width=3)
    d.polygon([(0, 0), (22, 0), (0, 22)], fill="yellow")  # marks the top-left corner
    buf = BytesIO()
    img.rotate(180).save(buf, "JPEG", quality=90)
    return buf.getvalue()


def send_image(fd, slot: int, data: bytes):
    # BAT <len hi> <len lo> <slot>, then raw JPEG split in 1024-byte reports
    cmd(fd, b"BAT", 0, 0, len(data) >> 8, len(data) & 0xFF, slot)
    for i in range(0, len(data), PACKET):
        send(fd, data[i : i + PACKET])


def main():
    args = [a for a in sys.argv[1:] if a.startswith("/dev/")]
    path = args[0] if args else find_device()
    seconds = int(sys.argv[sys.argv.index("--seconds") + 1]) if "--seconds" in sys.argv else 600
    fd = os.open(path, os.O_RDWR)
    print(f"opened {path}", flush=True)

    cmd(fd, b"DIS")
    cmd(fd, b"LIG", 0, 0, 80)
    cmd(fd, b"CLE", 0, 0, 0, 0xFF)
    cmd(fd, b"STP")

    colors = ["#c0392b", "#d35400", "#27ae60", "#2980b9", "#8e44ad", "#16a085", "#7f8c8d", "#2c3e50"]
    for slot in range(1, 16):
        # guess from opendeck-akp05: slots 1-4 are the touch strip (176x112), the rest are keys
        size = (176, 112) if slot <= 4 else (112, 112)
        send_image(fd, slot, jpeg(str(slot), size, colors[slot % len(colors)]))
    cmd(fd, b"STP")
    print("painted slots 1-15; listening (Ctrl-C to stop)", flush=True)

    end = time.time() + seconds
    last_keepalive = time.time()
    while time.time() < end:
        r, _, _ = select.select([fd], [], [], 1.0)
        if r:
            data = os.read(fd, 512)
            if data[:3] == b"ACK":
                print(f"{time.strftime('%H:%M:%S')} input=0x{data[9]:02x} state=0x{data[10]:02x} raw={data[:16].hex(' ')}", flush=True)
            else:
                print(f"{time.strftime('%H:%M:%S')} other raw={data[:16].hex(' ')}", flush=True)
        if time.time() - last_keepalive > 10:
            cmd(fd, b"CONNECT")
            last_keepalive = time.time()
    os.close(fd)


if __name__ == "__main__":
    main()
