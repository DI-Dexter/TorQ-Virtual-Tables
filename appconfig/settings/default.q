system"c 23 2000"

// ---------------------------------------------------------------------------
// End-of-day roll time, applied to every process.
//
// The stack's business day is GMT (appconfig/settings/segmentedtickerplant.q), so with the
// default offset of zero the day rolls at midnight UTC.
//
// Set an offset to model a business day that ends elsewhere -- 0D09:00 rolls at 09:00 UTC,
// which is 17:00 in a UTC+8 timezone.
//
// NOTE an offset moves the business-day BOUNDARY, not just the event: with a 9h offset a UTC
// timestamp before 09:00 belongs to the previous business date. That is what the setting is
// for, but it does mean the current partition reads as the previous date until the roll
// fires -- and therefore that .z.D and the live partition disagree for offset hours a day.
// The reader takes the live partition from disk rather than .z.D for exactly this reason
// (docs/virtual-table-capture-pack.md 5.8).
//
// code/common/eodtime.q loads after this file and reads the value with @[value;...], so a
// setting here survives rather than being clobbered.
// ---------------------------------------------------------------------------
\d .eodtime
rolltimeoffset:0D00:00:00.000
\d .
