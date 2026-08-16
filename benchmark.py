#!/usr/bin/env python3
"""
benchmark.py
------------
Script para realizar pruebas de carga y medir el overhead de OpenTelemetry.

Uso:
    python benchmark.py --url http://localhost:8000/order --requests 200 --concurrency 10 --tag "Sin_OTel"
    python benchmark.py --url http://localhost:8000/order --requests 200 --concurrency 10 --tag "Con_OTel"
"""

import sys
import time
import json
import argparse
import statistics
from concurrent.futures import ThreadPoolExecutor, as_completed
import urllib.request
import urllib.error


def send_request(url: str, payload: dict, timeout: float = 5.0) -> tuple:
    """Envía una única petición POST y retorna (latencia_ms, status_code, ok)"""
    data = json.dumps(payload).encode('utf-8')
    req = urllib.request.Request(
        url,
        data=data,
        headers={'Content-Type': 'application/json'},
        method='POST'
    )
    start_time = time.perf_counter()
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            elapsed_ms = (time.perf_counter() - start_time) * 1000.0
            return (elapsed_ms, resp.status, True)
    except urllib.error.HTTPError as e:
        elapsed_ms = (time.perf_counter() - start_time) * 1000.0
        return (elapsed_ms, e.code, False)
    except Exception as e:
        elapsed_ms = (time.perf_counter() - start_time) * 1000.0
        return (elapsed_ms, 0, False)


def calculate_percentile(data: list, percentile: float) -> float:
    """Calcula el percentil de una lista ordenada"""
    if not data:
        return 0.0
    size = len(data)
    idx = (percentile / 100.0) * (size - 1)
    lower = int(idx)
    upper = lower + 1
    if upper >= size:
        return data[-1]
    weight = idx - lower
    return data[lower] * (1.0 - weight) + data[upper] * weight


def run_benchmark(url: str, total_requests: int, concurrency: int, tag: str, payload: dict):
    print(f"\n==================================================")
    print(f"🚀 Iniciando Benchmark [{tag}]")
    print(f"==================================================")
    print(f"• URL objetivo   : {url}")
    print(f"• Peticiones     : {total_requests}")
    print(f"• Concurrencia   : {concurrency} hilos")
    print(f"• Payload        : {json.dumps(payload)}")
    print(f"--------------------------------------------------")

    latencies = []
    successes = 0
    failures = 0

    wall_start = time.perf_counter()

    with ThreadPoolExecutor(max_workers=concurrency) as executor:
        futures = [executor.submit(send_request, url, payload) for _ in range(total_requests)]
        for i, future in enumerate(as_completed(futures), 1):
            lat_ms, status, ok = future.result()
            latencies.append(lat_ms)
            if ok:
                successes += 1
            else:
                failures += 1

            if i % max(1, total_requests // 5) == 0 or i == total_requests:
                print(f"Progress: {i}/{total_requests} peticiones completadas...")

    total_time_sec = time.perf_counter() - wall_start
    rps = total_requests / total_time_sec if total_time_sec > 0 else 0.0

    sorted_lat = sorted(latencies) if latencies else [0.0]
    min_lat = sorted_lat[0]
    max_lat = sorted_lat[-1]
    mean_lat = statistics.mean(sorted_lat) if sorted_lat else 0.0
    p50_lat = calculate_percentile(sorted_lat, 50)
    p90_lat = calculate_percentile(sorted_lat, 90)
    p95_lat = calculate_percentile(sorted_lat, 95)
    p99_lat = calculate_percentile(sorted_lat, 99)

    summary = {
        "tag": tag,
        "total_requests": total_requests,
        "concurrency": concurrency,
        "successes": successes,
        "failures": failures,
        "total_time_sec": round(total_time_sec, 3),
        "rps": round(rps, 2),
        "latencies_ms": {
            "min": round(min_lat, 2),
            "mean": round(mean_lat, 2),
            "p50": round(p50_lat, 2),
            "p90": round(p90_lat, 2),
            "p95": round(p95_lat, 2),
            "p99": round(p99_lat, 2),
            "max": round(max_lat, 2)
        }
    }

    print("\n📊 RESULTADOS DEL BENCHMARK")
    print("--------------------------------------------------")
    print(f"🏷️  Etiqueta              : {tag}")
    print(f"⏱️  Tiempo Total          : {summary['total_time_sec']} s")
    print(f"⚡ Throughput (RPS)       : {summary['rps']} req/s")
    print(f"✅ Exitosas / ❌ Fallidas : {successes} / {failures}")
    print("--------------------------------------------------")
    print("📈 LATENCIAS (ms):")
    print(f"   • Mínima    : {summary['latencies_ms']['min']} ms")
    print(f"   • Promedio  : {summary['latencies_ms']['mean']} ms")
    print(f"   • Mediana P50: {summary['latencies_ms']['p50']} ms")
    print(f"   • Percentil 95: {summary['latencies_ms']['p95']} ms")
    print(f"   • Percentil 99: {summary['latencies_ms']['p99']} ms")
    print(f"   • Máxima    : {summary['latencies_ms']['max']} ms")
    print("--------------------------------------------------\n")

    print("📋 TABLA PARA INFORME (Markdown):")
    print(f"| Métrica | {tag} |")
    print(f"|---|---|")
    print(f"| Peticiones Exitosas | {successes}/{total_requests} |")
    print(f"| Tiempo Total (s) | {summary['total_time_sec']} |")
    print(f"| Throughput (RPS) | {summary['rps']} req/s |")
    print(f"| Latencia P50 (ms) | {summary['latencies_ms']['p50']} ms |")
    print(f"| Latencia P95 (ms) | {summary['latencies_ms']['p95']} ms |")
    print(f"| Latencia P99 (ms) | {summary['latencies_ms']['p99']} ms |")
    print(f"| Latencia Promedio (ms) | {summary['latencies_ms']['mean']} ms |")
    print("\n")

    return summary


def main():
    parser = argparse.ArgumentParser(description="Benchmark de Overhead para OpenTelemetry")
    parser.add_argument("--url", default="http://localhost:8000/order", help="URL del endpoint a probar")
    parser.add_argument("-n", "--requests", type=int, default=200, help="Total de peticiones a enviar")
    parser.add_argument("-c", "--concurrency", type=int, default=10, help="Número de hilos concurrentes")
    parser.add_argument("--tag", default="Prueba", help="Etiqueta para identificar la ejecución (ej: Sin_OTel / Con_OTel)")
    parser.add_argument("--item", default="laptop", help="Nombre del item para el payload de la orden")

    args = parser.parse_args()
    payload = {"item": args.item}
    run_benchmark(args.url, args.requests, args.concurrency, args.tag, payload)


if __name__ == "__main__":
    main()
