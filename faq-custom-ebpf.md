# FAQ: Can I Import Custom eBPF Scripts into NOO?

## Short Answer

**No.** The Network Observability Operator does NOT support loading custom or
user-defined eBPF programs. The eBPF code is pre-compiled and embedded inside
the agent container image. There is no plugin system, no extension mechanism,
and no way to inject custom packet processing logic at runtime.

However, there ARE two supported extension points for custom data collection:

1. **Custom GRPC collector** — build your own flow data consumer
2. **Custom OpenTelemetry field mapping** — customize the export format

---

## What the eBPF Agent Actually Contains

The NOO eBPF agent (`netobserv-ebpf-agent`) has its eBPF program written in C,
compiled to BPF bytecode, and embedded into Go source files during build time:

```
Source:   bpf/            ← C code for the eBPF program
Compiled: pkg/ebpf/bpf_*  ← generated Go files with embedded BPF bytecode
```

From the [upstream README](https://github.com/netobserv/netobserv-ebpf-agent):
> "The eBPF program is embedded into the `pkg/ebpf/bpf_*` generated files.
> Regenerating the kernel binaries is generally not needed unless you change
> the C code in the `bpf` folder."

This means:
- The eBPF program is baked into the container image at build time
- You cannot load additional eBPF programs at runtime
- To modify the eBPF logic, you'd need to fork the agent, modify the C code,
  recompile, and build a custom container image
- The `EbpfManager` feature only changes WHO loads the NOO's own programs
  (bpfman instead of the agent) — it does NOT allow loading custom programs

---

## Extension Point 1: Custom GRPC Collector

The eBPF agent exports flow records via GRPC+Protobuf. The default consumer is
the flowlogs-pipeline (FLP). But the upstream project provides a library for
building your own collector:

From the [upstream README](https://github.com/netobserv/netobserv-ebpf-agent):
> "We provide a simple GRPC+Protobuf library to allow implementing your own collector."

This means you can:
- Write a Go program that receives flow records from the eBPF agent
- Process them however you want (custom alerting, custom storage, custom analysis)
- Run it alongside FLP or instead of FLP

What you CANNOT do:
- Change what the eBPF agent captures (the fields are fixed)
- Add new packet inspection logic (that requires modifying the C code)
- Load custom eBPF programs at runtime

Example: The upstream repo has a [packet counter example](https://github.com/netobserv/netobserv-ebpf-agent)
that shows how to build a custom collector.

---

## Extension Point 2: Custom OpenTelemetry Field Mapping

The flowlogs-pipeline can export flows in OpenTelemetry format. The field names
can be customized:

> "Custom fields can be mapped to an OpenTelemetry conformant format. By default,
> the NetObserv format proposal is used, but as there is currently no accepted
> standard for L3 or L4 enriched network logs, you can freely override it with
> your own."

This lets you integrate NOO flow data into existing OpenTelemetry observability
platforms with your own field naming conventions.

---

## What If Someone Asks This at DevConf?

**Audience question:** "Can I import my own eBPF scripts into the operator?"

**Answer:**
> "No — the NOO's eBPF agent has a fixed, pre-compiled eBPF program embedded in
> the container image. You can't load custom eBPF programs at runtime. The
> `EbpfManager` feature only delegates loading of the NOO's OWN programs to an
> external bpfman operator — it's not for custom code.
>
> However, there are two extension points. First, you can build a custom GRPC
> collector using the upstream library — this lets you consume the flow data the
> agent exports and process it however you want. Second, you can customize the
> OpenTelemetry field mapping for export.
>
> If you truly need custom eBPF packet processing, look at tools like
> bpftrace, bcc, or Cilium Hubble — those are designed for custom eBPF programs.
> NOO is specifically for network flow observability with a fixed, optimized
> eBPF program that Red Hat supports."

---

## Sources

- [netobserv-ebpf-agent README](https://github.com/netobserv/netobserv-ebpf-agent)
- [FlowCollector API reference](https://github.com/netobserv/network-observability-operator/blob/main/docs/FlowCollector.md)
- [OCP 4.21 Network Observability docs](https://docs.redhat.com/en/documentation/openshift_container_platform/4.21/pdf/network_observability/OpenShift_Container_Platform-4.21-Network_Observability-en-US.pdf)
