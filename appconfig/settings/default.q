system"c 23 2000"

// End-of-day roll time, applied to every process. The business day is GMT
// (appconfig/settings/segmentedtickerplant.q), so an offset of zero rolls at midnight UTC.
// Set an offset to end the day elsewhere: 0D09:00 rolls at 09:00 UTC.
//
// NOTE an offset moves the business-day BOUNDARY, not just the event, so .z.D and the live
// partition disagree for those hours. The reader takes the live partition from disk rather
// than .z.D for exactly this reason (doc 5.8).
\d .eodtime
rolltimeoffset:0D00:00:00.000
\d .
