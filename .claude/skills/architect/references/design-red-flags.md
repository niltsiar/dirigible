# Design red flags

Screen every candidate before synthesis. A red flag is a reason to revise or reject the shape.

## Shallow module

A large interface hides little: callers coordinate several methods for one operation, or public options expose internal stages. A deep module concentrates capability behind one interface; a deep call chain scatters it.

## Information leakage

Several modules depend on one internal decision (a representation, a policy, a wire format), so a change needs edits in each. Parse external data into domain types behind the interface; keep storage schemas and framework objects private.

## Temporal decomposition

Modules follow execution order (load, validate, save), not the knowledge they own, and repeat one representation across the boundaries. Group code by the decisions it protects.

## Pass-through method

A method forwards its arguments to a method of the same shape and hides nothing. Remove it, or keep it only when it adds policy or adaptation.

## Split ownership

Two types own parts of one invariant (a session and its view model both track the selection), so neither keeps it true. Give the invariant one owner.

## Two ways to do one task

Two code paths do one job, for example two ways to write a package. Keep one path, move the callers to it, and delete the other in the same change.

## Importable internals

A declaration is `public` only for a test or one caller. Keep it `internal` or `private`; a test uses `@testable import`.

## Hand-synced list

A list (cases, keys, file names) has a hand-made copy in a doc, a switch, or a test. Derive the copy from the source, or add a check that fails when they differ.
