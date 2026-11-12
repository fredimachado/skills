# C# 9

The SDK-style default for `net5.0`. The examples use C# 9 syntax.

## Record classes, `init`, and `with`

```csharp
public sealed record Endpoint(string Host, int Port);

public static class Endpoints
{
    public static Endpoint UseTls(Endpoint endpoint) => endpoint with { Port = 443 };
}
```

- A positional record class synthesizes public `init` properties, a constructor, and `Deconstruct`. Record classes also synthesize value equality, hashing, and printable members. Use records for values when member-by-member equality fits the domain. Check custom equality, identity-based consumers, inheritance, serializers, and constructor attributes before converting a class. Array and list properties still use their own equality semantics.
- Record class equality distinguishes runtime record types. A `with` on a base-typed record copies the runtime record type. The default copy is shallow, so mutable reference members are shared. A property computed and cached during construction can become stale after `with`. Compute it from current values where appropriate.
- Use `init` on an ordinary class when callers should set a property during construction or in an object initializer. An omitted property keeps its default or initializer value. Preserve validation in the accessor and check callers before changing an existing `set` to `init`. The compiler needs `IsExternalInit` in the reference set for init accessors. Prefer the target's supported APIs or existing compatibility setup.
- Record structs and `with` on structs or anonymous types arrive in [C# 10](csharp-10.md). `required` arrives in [C# 11](csharp-11.md). [Records and init-only properties](https://devblogs.microsoft.com/dotnet/c-9-0-on-the-record/)

## Patterns and target typing

```csharp
public static class Syntax
{
    public static bool IsPercentage(int value) => value is >= 0 and <= 100;

    public static bool HasValue(object? value) => value is not null;

    public static System.Collections.Generic.List<int> Empty() => new();

    public static object Choose(bool useNumber) => useNumber ? 42 : "unknown";
}
```

- C# 9 adds type-only patterns and relational patterns against constants, plus `not`, `and`, and `or`. They bind in that order, from tightest to loosest. Parenthesize mixed patterns when the grouping could be misread. `is null` and `is not null` bypass user-defined equality operators. Check semantics before replacing an overloaded equality check.
- Target-typed `new()` needs a known constructible type. `var items = new();` cannot infer it. Keep the type visible where the initializer would otherwise be hard to understand. At overloaded call sites, use an explicit type if binding becomes ambiguous.
- A conditional can convert to a target type if both arms convert to it. Check overload selection and retain the order of side effects. `var` still needs the conditional to have a type on its own. [C# 9 proposals](https://github.com/dotnet/csharplang/tree/main/proposals/csharp-9.0)

## Entry points, lambdas, and enumeration

- Use top-level statements for a small executable entry point. Put `using` directives first and type or namespace declarations after the statements. Only one source file can contain top-level statements. Preserve access to `args`, async completion, exit codes, and any entry-point visibility required by tests or frameworks. Library projects and programs that need explicit entry-point control can keep `Main`.
- A `static` lambda or anonymous method prevents captures of locals and `this`. Static members and constants remain available. The modifier gives a compile-time capture check, with no guarantee about emitted method shape or allocation. `static` local functions were available earlier.
- Write `(_, _) => ...` to discard multiple lambda parameters. A single `_` parameter still has its ordinary name for compatibility. Local functions can carry attributes on the declaration, parameters, type parameters, and return value. Check `AttributeUsage` and use `return:` when the attribute targets the result.
- `foreach` can find an applicable extension `GetEnumerator` when its earlier enumeration paths fail. Check import scope and the enumerator's accessible `Current` and `MoveNext()` pattern, along with disposal. Adding an extension may affect any compatible type in scope. [C# language history](https://learn.microsoft.com/en-us/dotnet/csharp/whats-new/csharp-version-history#c-version-9)

## Overrides, partial methods, and nullable analysis

- Covariant returns let an override of a class method or read-only property return a more derived reference type. Check runtime support and public API compatibility. Calls through the base type retain the base signature. Setter-bearing overrides still need the matching property type.
- Partial methods can declare accessibility, non-`void` results, `out` parameters, and modifiers such as `virtual` or `override`. These forms need an explicit accessibility modifier and an implementation. An eligible legacy `partial void` with implicit private accessibility can still be omitted, in which case the compiler removes calls and argument evaluation.
- With nullable annotations enabled, unconstrained type parameters can be annotated `T?`. For a reference-type substitution it denotes a nullable reference, and for a value-type substitution it denotes the same value type. For a nullable value-type substitution API, use `where T : struct` with `T?`. `where T : default` resolves the unconstrained override or explicit interface implementation case. C# 9 also refines constructor and default-parameter null analysis. Treat new diagnostics as flow or contract issues before adding suppressions. [C# 9 proposals](https://github.com/dotnet/csharplang/tree/main/proposals/csharp-9.0)

## Native integers, function pointers, and initialization

- `nint` and `nuint` express pointer-sized integers for interop and native-size arithmetic. Check 32-bit and 64-bit behavior, checked conversions, ABI, and serialization widths. C# 11 makes them aliases of `System.IntPtr` and `System.UIntPtr`.
- `delegate*<int, int>` is a managed function pointer taking and returning `int`. Use an `unsafe` context and `/unsafe`, and use `&` on a compatible static method. Match the ABI exactly when using `delegate* unmanaged[...]`. Keep delegates where capture, managed lifetime, or marshalling conventions require them.
- `[ModuleInitializer]` is for code that must run at module initialization. Use an accessible, static, parameterless, nongeneric `void` method in a nongeneric type. Keep initialization deterministic and account for startup failures and side effects. Prefer explicit startup when dependencies or order matter.
- `[SkipLocalsInit]` suppresses the emitted locals-init flag. It requires an unsafe build and can expose uninitialized `stackalloc` contents. Use it only for a measured low-level need with proof that every read sees initialized data. C# definite assignment rules still apply to ordinary locals. [C# language history](https://learn.microsoft.com/en-us/dotnet/csharp/whats-new/csharp-version-history#c-version-9)
