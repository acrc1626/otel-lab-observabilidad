#!/usr/bin/env python3
"""
benchmark.py
------------
Script para realizar pruebas de carga y medir el overhead de OpenTelemetry.
Extiende el script original de Alex agregando monitoreo de CPU y memoria
del proceso objetivo durante la ejecución del benchmark.

Requiere: pip install psutil --break-system-packages

Uso:
    python benchmark.py --url http://localhost:8000/order --requests 200 --concurrency 10 --tag "Sin_OTel" --pid 12345
    python benchmark.py --url http://localhost:8000/order --requests 200 --concurrency 10 --tag "Con_OTel" --pid 12345

Para obtener el PID del proceso de service-a/service-b en Windows:
    Get-Process python | Select-Object Id, ProcessName
"""

import sys
import time
import json
import argparse
import statistics
import threading
from concurrent.futures import ThreadPoolExecutor, as_completed
import urllib.request
import urllib.error

try:
    import psutil
except ImportError:
    psutil = None


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
    except Exception:
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


class ResourceMonitor:
    """
    Muestrea CPU% y memoria (RSS en MB) de un proceso cada `interval`
    segundos, en un hilo separado, mientras el benchmark corre.
    """

    def __init__(self, pid: int, interval: float = 0.5):
        self.pid = pid
        self.interval = interval
        self.cpu_samples = []
        self.mem_samples_mb = []
        self._stop_event = threading.Event()
        self._thread = None
        self._process = None
        self._error = None

    def _run(self):
        try:
            self._process = psutil.Process(self.pid)
            # Primera llamada "arranca" el cálculo de cpu_percent (siempre da 0.0)
            self._process.cpu_percent(interval=None)
        except psutil.NoSuchProcess:
            self._error = f"No existe un proceso con PID {self.pid}"
            return

        while not self._stop_event.is_set():
            try:
                cpu = self._process.cpu_percent(interval=self.interval)
                mem_mb = self._process.memory_info().rss / (1024 * 1024)
                self.cpu_samples.append(cpu)
                self.mem_samples_mb.append(mem_mb)
            except psutil.NoSuchProcess:
                self._error = "El proceso terminó durante el monitoreo"
                break

    def start(self):
        if psutil is None:
            self._error = "psutil no está instalado (pip install psutil --break-system-packages)"
            return
        self._thread = threading.Thread(target=self._run, daemon=True)
        self._thread.start()

    def stop(self):
        self._stop_event.set()
        if self._thread:
            self._thread.join(timeout=2)

    def summary(self):
        if self._error:
            return {"error": self._error}
        if not self.cpu_samples:
            return {"error": "No se capturaron muestras"}
        return {
            "cpu_percent_avg": round(statistics.mean(self.cpu_samples), 2),
            "cpu_percent_max": round(max(self.cpu_samples), 2),
            "mem_mb_avg": round(statistics.mean(self.mem_samples_mb), 2),
            "mem_mb_max": round(max(self.mem_samples_mb), 2),
            "samples": len(self.cpu_samples),
        }


def run_benchmark(url: str, total_requests: int, concurrency: int, tag: str, payload: dict, pid: int = None):
    print(f"\n==================================================")
    print(f"🚀 Iniciando Benchmark [{tag}]")
    print(f"==================================================")
    print(f"• URL objetivo   : {url}")
    print(f"• Peticiones     : {total_requests}")
    print(f"• Concurrencia   : {concurrency} hilos")
    print(f"• Payload        : {json.dumps(payload)}")
    if pid:
        print(f"• Monitoreando PID: {pid} (CPU/memoria)")
    print(f"--------------------------------------------------")

    monitor = None
    if pid:
        monitor = ResourceMonitor(pid)
        monitor.start()

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

    resource_summary = {}
    if monitor:
        monitor.stop()
        resource_summary = monitor.summary()

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
        },
        "resources": resource_summary,
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
    if resource_summary and "error" not in resource_summary:
        print("--------------------------------------------------")
        print("🖥️  RECURSOS (proceso monitoreado):")
        print(f"   • CPU promedio : {resource_summary['cpu_percent_avg']} %")
        print(f"   • CPU máxima   : {resource_summary['cpu_percent_max']} %")
        print(f"   • Memoria prom.: {resource_summary['mem_mb_avg']} MB")
        print(f"   • Memoria máx. : {resource_summary['mem_mb_max']} MB")
        print(f"   • Muestras     : {resource_summary['samples']}")
    elif resource_summary and "error" in resource_summary:
        print("--------------------------------------------------")
        print(f"⚠️  Monitoreo de recursos no disponible: {resource_summary['error']}")
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
    if resource_summary and "error" not in resource_summary:
        print(f"| CPU Promedio (%) | {resource_summary['cpu_percent_avg']} % |")
        print(f"| CPU Máxima (%) | {resource_summary['cpu_percent_max']} % |")
        print(f"| Memoria Promedio (MB) | {resource_summary['mem_mb_avg']} MB |")
        print(f"| Memoria Máxima (MB) | {resource_summary['mem_mb_max']} MB |")
    print("\n")

    return summary


def main():
    parser = argparse.ArgumentParser(description="Benchmark de Overhead para OpenTelemetry")
    parser.add_argument("--url", default="http://localhost:8000/order", help="URL del endpoint a probar")
    parser.add_argument("-n", "--requests", type=int, default=200, help="Total de peticiones a enviar")
    parser.add_argument("-c", "--concurrency", type=int, default=10, help="Número de hilos concurrentes")
    parser.add_argument("--tag", default="Prueba", help="Etiqueta para identificar la ejecución (ej: Sin_OTel / Con_OTel)")
    parser.add_argument("--item", default="laptop", help="Nombre del item para el payload de la orden")
    parser.add_argument("--pid", type=int, default=None, help="PID del proceso de service-a/service-b a monitorear (CPU/memoria)")

    args = parser.parse_args()
    payload = {"item": args.item}
    run_benchmark(args.url, args.requests, args.concurrency, args.tag, payload, pid=args.pid)


if __name__ == "__main__":
    main()