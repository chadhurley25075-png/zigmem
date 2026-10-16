//! Medical classifier for household rows: cue words, dose units, drug-name suffixes. Biased to say "medical" when unsure
//! (a false positive only narrows who may see a row; a false negative could leak one person's health to another).
const std = @import("std");

const cues = [_][]const u8{
    "med",          "meds",         "medication",  "medications",  "medicine",     "medicines",   "medical",
    "prescription", "prescriptions", "prescribed", "rx",           "mg",           "mcg",         "dose",
    "doses",        "dosage",       "pill",        "pills",        "tablet",       "tablets",     "capsule",
    "capsules",     "inhaler",      "insulin",     "injection",    "diagnosis",    "diagnosed",   "condition",
    "disorder",     "syndrome",     "therapy",     "therapist",    "surgery",      "surgeon",     "allergy",
    "allergic",     "allergies",    "symptom",     "symptoms",     "labs",         "antibiotic",  "antibiotics",
    "refill",       "refills",      "pharmacy",    "pharmacist",   "doctor",       "clinic",      "hospital",
    "psychiatrist", "pediatrician", "dentist",     "biopsy",       "blood",        "cholesterol", "a1c",
    "adhd",         "eczema",       "allergy",     "asthma",       "diabetes",     "anxiety",     "depression",
    "migraine",     "migraines",    "uti",         "abscess",      "infection",    "seizure",     "seizures",
    "loratadine",   "lisinopril",   "atorvastatin", "amoxicillin",  "adderall",     "ibuprofen",   "aleve",
    "naproxen",     "ketorolac",    "omeprazole",  "levothyroxine", "metformin",    "zoloft",      "wellbutrin",
    "tylenol",      "acetaminophen", "hormone",    "hormones",     "vaccine",      "stitches",    "fracture",
};

/// Generic drug-name endings (INN stems). Only checked on words of 6+ letters.
const suffixes = [_][]const u8{
    "pril",   "olol",   "statin", "azole",   "cillin",  "mycin",   "cycline", "triptan", "oxetine", "traline", "pramine",
    "azepam", "azolam", "tidine", "sartan",  "dronate", "profen",  "codone",  "phetamine", "fenac", "semide", "thiazide",
    "lukast", "zodone", "barbital", "tropin", "parin", "floxacin",
};

const units = [_][]const u8{ "mg", "mcg", "ml", "iu" };

fn isCue(w: []const u8) bool {
    for (cues) |c| if (std.mem.eql(u8, c, w)) return true;
    if (w.len >= 6) for (suffixes) |s| if (std.mem.endsWith(u8, w, s)) return true;
    // "20mg", "0.5mcg" (split on '.', so "5mcg")
    var i: usize = 0;
    while (i < w.len and std.ascii.isDigit(w[i])) i += 1;
    if (i > 0 and i < w.len) for (units) |u| if (std.mem.eql(u8, w[i..], u)) return true;
    return false;
}

/// True when the text reads as a health / medication / condition statement.
pub fn isMedical(text: []const u8) bool {
    var buf: [64]u8 = undefined;
    var i: usize = 0;
    while (i < text.len) {
        while (i < text.len and !std.ascii.isAlphanumeric(text[i])) i += 1;
        const s = i;
        while (i < text.len and std.ascii.isAlphanumeric(text[i])) i += 1;
        if (i == s) break;
        const w = text[s..i];
        if (w.len > buf.len) continue;
        if (isCue(std.ascii.lowerString(&buf, w))) return true;
    }
    return false;
}

test "medical classifier" {
    const t = std.testing;
    try t.expect(isMedical("[SYNTHETIC] Morgan takes 20 mg of zorvatraline each morning."));
    try t.expect(isMedical("Rowan's new prescription is ready"));
    try t.expect(isMedical("Jordan takes 40mg daily"));
    try t.expect(isMedical("Quinn is on velmoprazole"));
    try t.expect(isMedical("Alex's labs came back"));
    try t.expect(!isMedical("Morgan likes the teal nail polish."));
    try t.expect(!isMedical("Rowan takes the bus on Tuesdays."));
    try t.expect(!isMedical("The wifi password rule: ask a parent."));
}
