/ Schema, as published by the Finance Starter Pack feed.
/ .
/ sym is the partition column: the writer strips it from the files and carries it in the
/ directory name instead (§4.5). It is declared in appconfig/sort.csv and exposed back to
/ clients under the same name by the reader's `partitioncol` setting.

quote:([]
  time:`timestamp$();
  sym:`g#`symbol$();
  bid:`float$();
  ask:`float$();
  bsize:`long$();
  asize:`long$();
  mode:`char$();
  ex:`char$();
  src:`symbol$()
 )

trade:([]
  time:`timestamp$();
  sym:`g#`symbol$();
  price:`float$();
  size:`int$();
  stop:`boolean$();
  cond:`char$();
  ex:`char$();
  side:`symbol$()
 )
