"""Minimal cemuhook/DSU pad server for Dolphin (one virtual pad in slot 0).

Usage: python dsu_server.py [log-file] [--port 26760] [--ctrl-port 26761]

The emulator connects as a DSU client to 127.0.0.1:<port>. A second UDP port
(<ctrl-port>, localhost only) accepts text commands to change the pad state:
  press <Input> <ms>    hold an input for <ms> then release (e.g. press Cross 150)
  hold <Input>          hold until "release <Input>"
  release <Input>
  stick <lx> <ly>       left stick bytes 0..255 (128 = center)
  quit
Inputs: Cross Circle Square Triangle L1 R1 L2 R2 PadN PadS PadE PadW Options Share
Events are appended to the log file (default dsu_log.txt). Use different ports
for each test that runs at the same time; both ports must be free.
"""
import argparse
import binascii
import socket
import struct
import sys
import threading
import time

VERSION = 1001
SERVER_ID = 0x1234ABCD
MSG_VERSION, MSG_PORTS, MSG_DATA = 0x100000, 0x100001, 0x100002

ANALOG = ["PadW", "PadS", "PadE", "PadN", "Square", "Cross", "Circle", "Triangle", "R1", "L1", "R2", "L2"]
BITS1 = {"Share": 0x1, "L3": 0x2, "R3": 0x4, "Options": 0x8}

lock = threading.Lock()
state = {name: 0 for name in ANALOG}
state.update({name: 0 for name in BITS1})
stick = [128, 128]
clients = {}
counter = 0
log_path = "dsu_log.txt"


def log(text):
    with open(log_path, "a", encoding="utf-8") as f:
        f.write(f"{time.strftime('%H:%M:%S')} {text}\n")


def packet(msg_type, payload):
    body = struct.pack("<I", msg_type) + payload
    header = b"DSUS" + struct.pack("<HHII", VERSION, len(body), 0, SERVER_ID)
    crc = binascii.crc32(header + body) & 0xFFFFFFFF
    header = b"DSUS" + struct.pack("<HHII", VERSION, len(body), crc, SERVER_ID)
    return header + body


def shared(slot):
    # slot, state=2 connected, model=2 DS4, connection=1 USB, mac, battery=5 full
    return struct.pack("<BBBB6sB", slot, 2, 2, 1, b"\x00\x11\x22\x33\x44\x55", 5)


def port_info(slot):
    if slot != 0:
        return packet(MSG_PORTS, struct.pack("<BBBB6sB", slot, 0, 0, 0, b"\x00" * 6, 0) + b"\x00")
    return packet(MSG_PORTS, shared(0) + b"\x00")


def pad_data():
    global counter
    counter += 1
    with lock:
        b1 = 0
        for name, bit in BITS1.items():
            if state[name]:
                b1 |= bit
        dpad_bits = (0x10 if state["PadN"] else 0) | (0x20 if state["PadE"] else 0) | \
                    (0x40 if state["PadS"] else 0) | (0x80 if state["PadW"] else 0)
        b1 |= dpad_bits
        b2 = (0x01 if state["L2"] else 0) | (0x02 if state["R2"] else 0) | (0x04 if state["L1"] else 0) | \
             (0x08 if state["R1"] else 0) | (0x10 if state["Triangle"] else 0) | (0x20 if state["Circle"] else 0) | \
             (0x40 if state["Cross"] else 0) | (0x80 if state["Square"] else 0)
        analog = bytes(255 if state[n] else 0 for n in ANALOG)
        lx, ly = stick
    payload = shared(0) + struct.pack("<BIBBBB", 1, counter, b1, b2, 0, 0)
    payload += bytes([lx, ly, 128, 128]) + analog
    payload += b"\x00" * 12  # two touch points
    payload += struct.pack("<Q6f", int(time.time() * 1e6) & 0xFFFFFFFFFFFFFFFF, 0, 0, 1, 0, 0, 0)
    return packet(MSG_DATA, payload)


def dsu_loop(sock):
    while True:
        try:
            data, addr = sock.recvfrom(1024)
        except ConnectionResetError:
            # Windows reports a closed client (ICMP port unreachable) on the next recv.
            continue
        if len(data) < 20 or data[:4] != b"DSUC":
            continue
        msg_type = struct.unpack_from("<I", data, 16)[0]
        if msg_type == MSG_VERSION:
            sock.sendto(packet(MSG_VERSION, struct.pack("<H", VERSION)), addr)
        elif msg_type == MSG_PORTS:
            count = struct.unpack_from("<i", data, 20)[0]
            for slot in data[24:24 + max(0, min(count, 4))]:
                sock.sendto(port_info(slot), addr)
        elif msg_type == MSG_DATA:
            if addr not in clients:
                log(f"client registered {addr}")
            clients[addr] = time.time()


def send_loop(sock):
    while True:
        now = time.time()
        for addr, seen in list(clients.items()):
            if now - seen > 5:
                del clients[addr]
                log(f"client dropped {addr}")
                continue
            try:
                sock.sendto(pad_data(), addr)
            except OSError:
                clients.pop(addr, None)
        time.sleep(0.004)


def set_input(name, value):
    with lock:
        if name not in state:
            raise KeyError(name)
        state[name] = value


def ctrl_loop(ctrl):
    while True:
        data, _ = ctrl.recvfrom(256)
        parts = data.decode().split()
        if not parts:
            continue
        try:
            if parts[0] == "press":
                set_input(parts[1], 1)
                log(f"press {parts[1]} {parts[2]}ms")
                time.sleep(int(parts[2]) / 1000)
                set_input(parts[1], 0)
            elif parts[0] == "hold":
                set_input(parts[1], 1)
                log(f"hold {parts[1]}")
            elif parts[0] == "release":
                set_input(parts[1], 0)
                log(f"release {parts[1]}")
            elif parts[0] == "stick":
                with lock:
                    stick[0], stick[1] = int(parts[1]), int(parts[2])
                log(f"stick {parts[1]} {parts[2]}")
            elif parts[0] == "quit":
                log("quit")
                raise SystemExit
        except (KeyError, IndexError, ValueError) as exc:
            log(f"bad command {parts}: {exc!r}")


def main():
    global log_path
    parser = argparse.ArgumentParser(description="Minimal DSU pad server (one pad, slot 0).")
    parser.add_argument("log", nargs="?", default="dsu_log.txt", help="event log file")
    parser.add_argument("--port", type=int, default=26760, help="DSU port the emulator connects to")
    parser.add_argument("--ctrl-port", type=int, default=26761, help="localhost port for text commands")
    args = parser.parse_args()
    log_path = args.log
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.bind(("127.0.0.1", args.port))
    if hasattr(socket, "SIO_UDP_CONNRESET"):
        sock.ioctl(socket.SIO_UDP_CONNRESET, False)
    ctrl = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    ctrl.bind(("127.0.0.1", args.ctrl_port))
    threading.Thread(target=dsu_loop, args=(sock,), daemon=True).start()
    threading.Thread(target=send_loop, args=(sock,), daemon=True).start()
    log(f"server up port={args.port} ctrl={args.ctrl_port}")
    try:
        ctrl_loop(ctrl)
    except SystemExit:
        pass


if __name__ == "__main__":
    main()
