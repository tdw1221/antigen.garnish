


#' Internal function to check for dev version of magrittr.
#'
#' @export check_dep_versions
#' @md

check_dep_versions <- function() {

  # require here so if bad version of magrittr this will return the stop error
  # otherwise will bug prior to returning error message
  require("data.table")
  require("stringr")

  if (!utils::installed.packages() %>%
    as.data.table() %>%
    .[Package == "magrittr", Version %>%
      str_replace_all("\\.", "") %>%
      as.numeric() >= 150]) {
    stop("magrittr version >= 1.5.0 is required and can be installed with:

       devtools::install_github(\"tidyverse/magrittr\")")
  }

  return(NULL)
}




#' Return a data table of available MHC types.
#'
#' @export list_mhc
#' @md

list_mhc <- function() {
  dt <- system.file("extdata",
    "all_alleles.txt",
    package = "antigen.garnish"
  ) %>%
    data.table::fread(header = FALSE, sep = "\t") %>%
    data.table::setnames("V1", "MHC") %>%
    .[, species := "human"] %>%
    .[MHC %likef% "H-2", species := "mouse"] %>%
    .[, class := "II"] %>%
    .[MHC %like% "(H-2-[A-Z][a-z])|(HLA-[ABCE]\\*)", class := "I"]

  return(dt)
}




#' Internal function to replace MHC with matching prediction tool MHC syntax
#'
#' @param x Vector of HLA types named for program to convert to.
#' @param alleles Data table of 2 columns, 1. formatted allele names 2. prediction tool name (e.g. mhcflurry, mhcnuggets, netMHC).
#'
#' @export detect_mhc
#' @md

detect_mhc <- function(x, alleles) {
  prog <- deparse(substitute(x))

  for (hla in (x %>% unique())) {
    if (hla %like% "all") next

    # match hla allele alelle (end|(not longer allele))
    hla_re <- paste0(hla, "($|[^0-9])")

    allele <- alleles[type == prog, allele %>%
      .[stringi::stri_detect_regex(., hla_re) %>% which()]] %>%
      # match to first in case of multiple matches
      # e.g. netMHCII
      .[1]

    if (allele %>% length() == 0) allele <- NA

    x[x == hla] <- allele
  }

  return(x)
}




#' Internal function to add metadata by `ensembl_transcript_id`
#'
#' @param dt Data table with `INFO` column.
#'
#' @export get_metadata
#' @md

get_metadata <- function(dt) {
  if (!"ensembl_transcript_id" %chin%
    (dt %>% names())) {
    stop("ensembl_transcript_id column missing")
  }


  # remove version suffix
  dt[, ensembl_transcript_id :=
    ensembl_transcript_id %>%
    stringr::str_replace("\\.[0-9]$", "")]

  message("Reading local transcript metadata.")

  # detect/set AG_DATA_DIR environmental variable
  check_pred_tools()

  # load metadata
  metafile <- file.path(Sys.getenv("AG_DATA_DIR"), "/GRChm38_meta.RDS")

  if (!file.exists(metafile)) {
    ag_data_err()
  }

  var_dt <- readRDS(metafile)

  dt <- merge(dt, var_dt, by = "ensembl_transcript_id")

  rm(var_dt)

  return(dt)
}




#' Internal function to create cDNA from HGVS notation
#'
#' @param dt Data table with INFO column.
#'
#' @export make_cDNA
#' @md

make_cDNA <- function(dt) {
  if (!c(
    "cDNA_type",
    "coding",
    "cDNA_locs",
    "cDNA_locl",
    "cDNA_seq"
  ) %chin%
    (dt %>% names()) %>% all()) {
    stop("dt is missing columns")
  }

  # initialize and set types

  dt[, coding_mut := coding]

  for (i in c("cDNA_locs", "cDNA_locl")) {
    set(dt, j = i, value = dt[, get(i) %>%
      as.integer()])
  }

  # remove if nonsensical loc
  dt %<>% .[, coding_nchar := coding %>% nchar()]

  dt %<>%
    .[!cDNA_locs > coding_nchar &
      !cDNA_locl > coding_nchar]

  dt[, coding_nchar := NULL]



  # paste substr around changed bases
  # substr is vectorized C, fast
  # mut sub nmers that are really wt
  # will be filtered after subpep generation


  # handle single base changes

  dt[
    cDNA_type == ">",
    coding_mut := coding_mut %>% {
      paste0(
        substr(., 1, cDNA_locs - 1),
        cDNA_seq,
        substr(
          .,
          cDNA_locs + 1,
          nchar(.)
        )
      )
    }
  ]

  # handle deletions
  # indices are inclusive
  # regexpr match for del

  dt[
    cDNA_type %like% "del",
    coding_mut := coding_mut %>% {
      paste0(
        substr(., 1, cDNA_locs - 1),
        substr(
          .,
          cDNA_locl + 1,
          nchar(.)
        )
      )
    }
  ]

  # handle insertions
  # regexpr match for del
  # this is off register by one for delins
  dt[
    cDNA_type == "ins",
    coding_mut := coding_mut %>% {
      paste0(
        substr(., 1, cDNA_locs),
        cDNA_seq,
        substr(
          .,
          cDNA_locs + 1,
          nchar(.)
        )
      )
    }
  ]

  # for delins, the cDNA_locs is a deleted base, so true s is now 1 off
  dt[
    cDNA_type == "delins",
    coding_mut := coding_mut %>% {
      paste0(
        substr(., 1, cDNA_locs - 1),
        cDNA_seq,
        substr(
          .,
          cDNA_locs,
          nchar(.)
        )
      )
    }
  ]
}




#' Internal function to extract a data table of variants with `INFO` fields in columns.
#'
#' @param vcf vcfR object to extract data from.
#'
#' @return Data table of variants with `INFO` fields in columns.
#'
#' @export get_vcf_info_dt
#' @md

get_vcf_info_dt <- function(vcf) {
  if (vcf %>% class() %>% .[1] != "vcfR") {
    stop("vcf input is not a vcfR object.")
  }

  dt <- vcf@fix %>% data.table::as.data.table()

  if (!"INFO" %chin% (dt %>% names())) {
    stop("Error parsing input file INFO field.")
  }

  # loop over INFO field
  # tolerant of variable length and content
  v <- dt[, INFO %>% paste(collapse = ";@@@=@@@;")]
  vd <- v %>%
    stringr::str_replace_all("(?<=;)[^=;]+", "") %>%
    stringr::str_replace_all(stringr::fixed("="), "")
  vn <- v %>%
    stringr::str_replace_all("(?<==)[^;]+", "") %>%
    stringr::str_replace_all(stringr::fixed("="), "")

  vd %<>% strsplit("@@@")
  vn %<>% strsplit(("@@@"))

  idt <- lapply(1:length(vn[[1]]), function(i) {
    v <- vd[[1]][i] %>%
      strsplit(";") %>%
      .[[1]]
    names(v) <- vn[[1]][i] %>%
      strsplit(";") %>%
      .[[1]]

    return(v %>% as.list())
  }) %>% rbindlist(fill = TRUE, use.names = TRUE)

  if (
    (dt %>% nrow()) !=
      (idt %>% nrow())
  ) {
    stop("Error parsing input file INFO field.")
  }

  dt <- cbind(dt, idt)

  return(dt)
}




#' Internal function to extract a data table from sample `vcf` fields.
#'
#' @param vcf vcfR object to extract data from.
#'
#' @return Data table of variants with sample level fields in columns.
#'
#' @export get_vcf_sample_dt
#' @md

get_vcf_sample_dt <- function(vcf) {
  if (vcf %>% class() %>% .[1] != "vcfR") {
    stop("vcf input is not a vcfR object.")
  }

  dt <- vcf@gt %>% data.table::as.data.table()

  if (!"FORMAT" %chin% (dt %>% names())) {
    stop("Error parsing input file sample level info.")
  }

  names <- vcf@gt %>%
    attributes() %>%
    .$dimnames %>%
    unlist() %excludef%
    "FORMAT"

  # loop over sample level data
  # tolerant of variable length and content

  # This used to  be doubly parallelized over samples in the vcf
  # would get weird recycling consistently with test data so I pulled this off.
  # this is will not substantially affect speed, only 2 samples to fork anyways.
  idt <- lapply(names, function(n) {
    ld <- dt[, get(n)]
    ln <- dt[, FORMAT]

    idt <- lapply(1:length(ln), function(i) {

      #  account for format columns longer than provided values, as in NORMAL vs. TUMOR with mutant
      # only one value is provided in tumor column for some values, like SA_POST_PROB  etc.
      nl <- ln[i] %>%
        strsplit(":") %>%
        .[[1]]
      l <- ld[i] %>%
        strsplit(":") %>%
        .[[1]]

      names(l) <- nl[1:length(l)]



      return(l %>% as.list())
    }) %>% rbindlist(fill = TRUE, use.names = TRUE)

    idt %>% data.table::setnames(
      idt %>% names(),
      idt %>% names() %>% paste0(n, "_", .)
    )
    return(idt)
  }) %>% do.call(cbind, .)

  # assign ref and alt to individual columns

  for (i in (idt %>% names() %include% "_AD$")) {
    colNum <- idt[, get(i) %>%
      data.table::tstrsplit(",") %>% length()]

    if (colNum == 2) {
      idt[, paste0(i, c("_ref", "_alt")) := get(i) %>%
        data.table::tstrsplit(",")]
    }
    if (colNum == 3) {
      idt[, paste0(i, c("_ref", "_alt", "_alt2")) := get(i) %>%
        data.table::tstrsplit(",")]
    }
    if (colNum == 4) {
      idt[, paste0(i, c("_ref", "_alt", "_alt2", "_alt3")) := get(i) %>%
        data.table::tstrsplit(",")]
    }
    if (colNum == 5) {
      idt[, paste0(i, c("_ref", "_alt", "_alt2", "_alt3", "_alt4")) := get(i) %>%
        data.table::tstrsplit(",")]
    }
    if (colNum > 5) {
      stop("Parsing VCFs with greater than 4 alternative alleles is not supported.")
    }

    set(idt, j = i, value = NULL)
  }

  if (
    (dt %>% nrow()) !=
      (idt %>% nrow())
  ) {
    stop("Error parsing input file INFO field.")
  }

  dt <- cbind(dt, idt)

  return(dt)
}




#' Internal function to extract SnpEff annotation information to a data table.
#'
#' @param dt Data table with character vector `ANN` column, from `vcf` file.
#'
#' @return Data table with the `ANN` column parsed into additional rows.
#'
#' @export get_vcf_snpeff_dt
#' @md

get_vcf_snpeff_dt <- function(dt) {
  if (!"ANN" %chin% (dt %>% names())) {
    stop("Error parsing input file ANN field from SnpEff.")
  }

  # add a variant identifier

  len <- nrow(dt)
  suppressWarnings(dt[, snpeff_uuid := uuid::UUIDgenerate(use.time = FALSE, n = len)])

  # spread SnpEff annotation over rows
  # transform to data frame intermediate to avoid
  # data.taable invalid .internal.selfref
  df <- dt %>%
    as.data.frame() %>%
    tidyr::separate_rows("ANN", sep = ",")
  dt <- df %>% data.table::as.data.table()

  # extract info from snpeff annotation
  dt[, effect_type := ANN %>%
    stringr::str_extract("^[^\\|]+\\|[^|]+") %>%
    stringr::str_replace("^[^\\|]+\\|", "")]
  dt[, ensembl_transcript_id := ANN %>%
    stringr::str_extract("(?<=\\|)(ENSMUST|ENST)[0-9]+")]
  dt[, ensembl_gene_id := ANN %>%
    stringr::str_extract("(?<=\\|)(ENSMUSG|ENSG)[0-9.]+(?=\\|)")]
  dt[, protein_change := ANN %>%
    stringr::str_extract("p\\.[^\\|]+")]
  dt[, cDNA_change := ANN %>%
    stringr::str_extract("c\\.[^\\|]+")]
  dt[, protein_coding := ANN %>%
    stringr::str_detect("protein_coding")]

  ## this is only for hg19
  dt[, refseq_id := ANN %>%
    stringr::str_extract("(?<=\\|)NM_[0-9]+")]

  if (nrow(dt[!is.na(refseq_id)]) > 0) {
    message("Annotations detected RefSeq identifiers, these will be converted to Ensembl transcript IDs, some data may be lost.
        Please annotate vcfs with Ensembl transcript IDs.")
  }

  if (nrow(dt[!is.na(refseq_id)]) == 0) dt[, refseq_id := NULL]

  return(dt)
}




#' Internal function to extract cDNA changes from HGVS notation
#'
#' @param dt Data table with INFO column.
#'
#' @export extract_cDNA
#' @md

extract_cDNA <- function(dt) {

  # check required cols

  if (!c("cDNA_change") %chin%
    (dt %>% names()) %>% all()) {
    stop("cDNA_change missing")
  }


  # extract HGVS DNA nomenclature
  # dups are just ins
  dt[, cDNA_change := cDNA_change %>%
    stringr::str_replace_all("dup", "ins")]

  dt[, cDNA_locs := cDNA_change %>%
    stringr::str_extract("[0-9]+") %>%
    as.integer()]
  dt[, cDNA_locl := cDNA_change %>%
    stringr::str_extract("(?<=_)[0-9]+") %>%
    as.integer()]
  # make cDNA_locl cDNA_locs for single bases
  dt[cDNA_locl %>% is.na(), cDNA_locl := cDNA_locs]

  dt[, cDNA_type := cDNA_change %>%
    # make cDNA deletes then inserts, if we have indel variants it will work
    # the pattern pulled will be delins
    stringr::str_extract_all("[a-z]{3}|>") %>%
    unlist() %>%
    paste(collapse = ""),
  by = 1:nrow(dt)
  ]
  dt[, cDNA_seq := cDNA_change %>%
    stringr::str_extract("[A-Z]+$")]

  # filter out extraction errors
  # https://github.com/andrewrech/antigen.garnish/issues/3
  dt %<>% .[!cDNA_locs %>% is.na() &
    !cDNA_locl %>% is.na() &
    !cDNA_type %>% is.na()]
}




#' Internal function to translate cDNA to peptides
#'
#' @param v cDNA character vector without ambiguous bases.
#'
#' @export translate_cDNA
#' @md

translate_cDNA <- function(v) {
  lapply(v, function(p) {

    # protect vector length
    tryCatch(
      {
        p %>%
          Biostrings::DNAString() %>%
          Biostrings::translate() %>%
          as.character()
      },
      error = function(e) {
        return(NA)
      }
    )
  }) %>% unlist()
}
