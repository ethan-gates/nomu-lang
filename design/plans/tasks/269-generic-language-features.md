# Generic language features

**Avenue:** Usability · **Type/Lifecycle:** `language-feature · needs-design` · **Size:** XL · **Status:** not
started, each needing design and agreement before it is built · **Source:** [253](253-finish-generics.md) 253.10,
moved out once 253's correctness work was done.

## What

What generics still cannot express. Each is a language change, so each needs a design and agreement before it is
built; each may become a task of its own when it is taken up.

## Steps

- **269.1** A method's own type parameters ([170](170-method-level-generics.md)).
- **269.2** Associated types and where-clauses ([118](118-associated-types.md)).
- **269.3** Operators as interface requirements: generic code cannot yet compare or hash a `T` (`generics.md` §10).
- **269.4** Static type-argument inference ([151](151-generic-type-methods.md)).
- **269.5** Mutating calls on a class's struct field, rejected today ([249](249-barrier-through-mutating-self.md)).

## Refs

`generics.md`; [253](253-finish-generics.md).
