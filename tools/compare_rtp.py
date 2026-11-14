#!/usr/bin/env python3
"""Compare two captures of the same RTP multicast stream."""
import argparse
import json
import statistics
import subprocess
from decimal import Decimal


def read_packets(path, port, ssrc):
    fields = ('frame.time_epoch', 'rtp.ssrc', 'rtp.seq', 'rtp.timestamp')
    command = [
        'tshark', '-n', '-r', path, '-d', f'udp.port=={port},rtp',
        '-Y', f'udp.dstport == {port} && rtp.ssrc == {ssrc}',
        '-T', 'fields',
    ]
    for field in fields:
        command.extend(('-e', field))
    output = subprocess.run(command, capture_output=True, text=True, check=True)
    packets = {}
    duplicates = 0
    for row in output.stdout.splitlines():
        arrival, _, sequence, timestamp = row.split('\t')
        key = (int(sequence), int(timestamp))
        if key in packets:
            duplicates += 1
        else:
            packets[key] = Decimal(arrival)
    return packets, duplicates


def compare(tx, rx, clock_rate):
    # Use the same RTP packets as boundaries independently of the host clocks.
    shared = [key for key in tx if key in rx]
    if len(shared) < 2:
        raise ValueError('Servono almeno due pacchetti comuni dello stesso SSRC.')
    first, last = shared[0], shared[-1]
    media = ((last[1] - first[1]) & 0xffffffff) / clock_rate
    if not 0 < media < (2**31 / clock_rate):
        raise ValueError('Timestamp RTP incompatibili con un flusso continuo.')

    def window(packets):
        start, end = packets[first], packets[last]
        elapsed = float(end - start)
        if elapsed <= 0:
            raise ValueError('Confini RTP fuori ordine nella cattura.')
        arrivals = {key: time for key, time in packets.items() if start <= time <= end}
        times = sorted(arrivals.values())
        gaps = [float(b - a) * 1000 for a, b in zip(times, times[1:])]
        return arrivals, {
            'elapsed_seconds': round(elapsed, 6),
            'rtp_ms_per_wall_second': round(1000 * media / elapsed, 3),
            'unique_packets': len(arrivals),
            'median_interarrival_ms': round(statistics.median(gaps), 3),
            'max_interarrival_ms': round(max(gaps), 3),
        }

    tx_window, tx_stats = window(tx)
    rx_window, rx_stats = window(rx)
    return {
        'shared_boundary_packets': [first, last],
        'rtp_span_seconds': round(media, 6),
        'tx': tx_stats,
        'rx': rx_stats,
        'observed_only_at_tx': len(tx_window.keys() - rx_window.keys()),
        'observed_only_at_rx': len(rx_window.keys() - tx_window.keys()),
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('tx', help='Cattura pcap o pcapng TX')
    parser.add_argument('rx', help='Cattura pcap o pcapng RX')
    parser.add_argument('--ssrc', required=True, type=lambda value: int(value, 0))
    parser.add_argument('--port', default=10001, type=int)
    parser.add_argument('--clock-rate', default=44100, type=int)
    args = parser.parse_args()
    if args.clock_rate <= 0 or not 0 < args.port <= 65535 or not 0 <= args.ssrc <= 0xffffffff:
        parser.error('Clock, porta o SSRC fuori intervallo.')
    try:
        tx, tx_duplicates = read_packets(args.tx, args.port, args.ssrc)
        rx, rx_duplicates = read_packets(args.rx, args.port, args.ssrc)
        result = compare(tx, rx, args.clock_rate)
    except subprocess.CalledProcessError as error:
        parser.exit(1, error.stderr or 'Lettura cattura fallita.\n')
    except (OSError, ValueError) as error:
        parser.exit(1, f'{error}\n')
    result['ssrc'] = args.ssrc
    result['duplicates_full_capture'] = {'tx': tx_duplicates, 'rx': rx_duplicates}
    print(json.dumps(result, indent=2))


if __name__ == '__main__':
    main()
