---
name: csharp-modernization
description: Write, review, and modernize C# code using features from C# 9 through C# 15. Use for version-aware refactors, language upgrades within this range, and diagnostics involving records, patterns, collection expressions, ref safety, extension members, unions, or closed hierarchies. Apply the project's effective language version and runtime constraints.
---

# C# modernization

Choose features that make the code clearer or solve a concrete problem. Use the lowest language version needed for the change, within the project's supported version and the user's requested range. The stable language ceiling for this skill is C# 15.

## Check the project first

1. Find the affected `.csproj` files and read `TargetFramework` or `TargetFrameworks`, `LangVersion`, and applicable `Directory.Build.props` and `.targets`. Check the SDK selected by `global.json` and `dotnet --version` from the repository. Conditions and imports can set a different language version per target.
2. If the effective settings are unclear, inspect the evaluated project, for example `dotnet msbuild App.csproj -p:TargetFramework=net8.0 -getProperty:TargetFramework,LangVersion`, or use a temporary `#error version` to get compiler diagnostic CS8304. Remove the directive after checking.
3. Use the table for SDK-style projects without a language version override. A newer SDK can build a project with an older language version. Check separately for runtime support and library types such as `System.Threading.Lock`, generic math interfaces, and compiler-recognized attributes.
4. Keep SDK, framework, package, and build settings within the requested scope. For an explicit upgrade, prefer the supported target framework's default or a specific supported numeric setting. `latest` varies with the toolchain. Use `preview` for explicitly requested preview work, such as the .NET 11 memory-safety preview. Microsoft supports the language version associated with the target framework and earlier versions.

| C# | Default target | Feature guide |
| --- | --- | --- |
| 9 | `net5.0` | [Records, init, patterns, top-level code, target typing, interop](references/csharp-9.md) |
| 10 | `net6.0` | [Record structs, namespaces, usings, lambdas, interpolated string handlers](references/csharp-10.md) |
| 11 | `net7.0` | [Required members, raw and UTF-8 literals, list patterns, generic math, ref fields](references/csharp-11.md) |
| 12 | `net8.0` | [Primary constructors, collection expressions, inline arrays, lambda defaults](references/csharp-12.md) |
| 13 | `net9.0` | [Params collections, `Lock`, ref structs, partial properties, overload resolution](references/csharp-13.md) |
| 14 | `net10.0` | [Extension members, `field`, null-conditional assignment, span conversions, file-based apps](references/csharp-14.md) |
| 15 | `net11.0` | [Collection expression arguments, unions, closed hierarchies, extension indexers, labeled jumps](references/csharp-15.md) |

The mapping describes language defaults. Use the project's support and upgrade requirements to choose a target. [Microsoft C# language versioning](https://learn.microsoft.com/en-us/dotnet/csharp/language-reference/language-versioning)

## Make and verify the change

- Read the guide for the feature you plan to use. When comparing syntax options, consider how the feature evolved. `init` restricts when a property can be set, `required` adds a caller obligation, and `field` preserves custom accessor logic while letting the compiler generate storage.
- Keep behavior in scope. Check construction, validation, equality, serialization, overload binding, evaluation order, and expression-tree translation where the edit touches them. Treat changes to public setters, constructors, operators, and delegate types as API changes.
- In a multi-targeted project, keep shared code valid across the applicable targets and configurations. Check code generation and analyzer settings before editing generated code or enabling a language-dependent style rule.
- Build affected projects and run the relevant existing tests. When a rewrite can silently select a different overload, evaluate an expression at a different time, or switch synchronization mechanisms, verify that behavior with a focused check.

## Diagnostics worth checking

| Signal | First check |
| --- | --- |
| CS8304 or a feature version error | Check the evaluated language version and selected SDK for the failing target. |
| CS0518 mentioning `IsExternalInit` | Check reference assemblies and any existing compatibility setup. |
| CS9035 | Check required member initialization and any constructor marked `SetsRequiredMembers`. |
| CS9176 | Give the collection expression a target type and check the overload selected. |
| CS0121 or CS0411 after a rewrite | Check ambiguous overloads and type inference. Consider an explicit target, type argument, or cast. |
| CS9216 | Check whether a `System.Threading.Lock` is converted before use in `lock`. |
| CS9258 | Check an existing identifier named `field` inside a property accessor. |
| CS8509 or CS8655 on a C# 15 switch | Check case coverage, inaccessible descendants, and nullable input. Test default-initialized unions separately. |

Use the language reference and shipped compiler to resolve disagreements with a feature proposal. [C# version history](https://learn.microsoft.com/en-us/dotnet/csharp/whats-new/csharp-version-history) · [Compiler changes in .NET 9](https://learn.microsoft.com/en-us/dotnet/csharp/whats-new/breaking-changes/compiler%20breaking%20changes%20-%20dotnet%209) · [Compiler changes in .NET 10](https://learn.microsoft.com/en-us/dotnet/csharp/whats-new/breaking-changes/compiler%20breaking%20changes%20-%20dotnet%2010) · [Compiler changes in .NET 11](https://learn.microsoft.com/en-us/dotnet/csharp/whats-new/breaking-changes/compiler%20breaking%20changes%20-%20dotnet%2011)
