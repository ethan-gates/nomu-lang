Inference dimensions

> Exploratory brainstorm, not a decision. The durable inference design and dimension inventory live in
> `design/internals/inference.md` (built by task `design/plans/tasks/164-formal-inference-stage.md`).
> How these five landed there: reachability and mutation/isolation were already covered;
> lives-across-suspension, inferred immutability, and transfer/handoff were adopted as future perf facts;
> reference uniqueness/aliasing was adopted as a perf fact (forms 1+2); cycle potential was dropped (the
> collector reclaims cycles).

These are compiler inference dimensions.  This is not about type inference (which is its own thing).  This is primarily about memory (GC included) and concurrency
inference.  The language hypothesis is that we can ellide explicit annotations such as in rust, pony, and to a lesser degree swift and replace it with strong
inference to achieve performance that can beat golang and swift.  These dimensions are a non-exhaustive (but maybe complete?) for this purpose.

1. Reachability — which execution contexts can potentially reach an object, including fiber-local, transferable, and concurrently shared.
2. Reference uniqueness / aliasing — whether the compiler can prove a single reference to an object, or whether aliases may exist.
3. Lifetime — how long the object must remain alive, including whether it must survive suspension, outlive its creating fiber, or remain globally reachable.
4. Mutation / isolation — whether the object can be mutated and whether that mutation is confined to one execution context or may occur concurrently.
5. Cycle potential — whether the object can participate in a reference cycle that prevents straightforward reference-count-based reclamation.
