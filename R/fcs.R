# fcs.R
# Functions for the import, quality control, and processing of Flow Cytometry
# Standard (FCS) files.

#' Astrolabe debris labels.
#' 
#' @return Vector of Astrolabe debris labels.
#' @export
astrolabeDebrisLabels <- function() {
  c("Debris", "Root_unassigned")
}

# FCS File Interaction --------------------------------------------------------

#' Test if a given object is an Astrolabe sample.
#'
#' Check whether the given object is a list, and whether it includes all of the
#' fields that we would expect from the default importFcsFile.
#'
#' @param sample Object to be tested.
#' @return TRUE if the object is an Astrolabe sample, FALSE otherwise.
#' @export
isSample <- function(sample) {
  default_fields <-
    c("exprs", "parameter_name", "parameter_desc", "source")

  if (!is.list(sample)) {
    FALSE
  } else {
    all(default_fields %in% names(sample))
  }
}

.massSuspectValues <- function() {
  # A list of suspect values. If too many of them are included in the
  # description field of an FCS file (and include additional values) we will
  # remove them.
  c(
    "89Y",   "Y89",   "113In", "In113", "115In", "In115", "141Pr", "Pr141",
    "142Nd", "Nd142", "143Nd", "Nd143", "144Nd", "Nd144", "145Nd", "Nd145",
    "146Nd", "Nd146", "147Sm", "Sm147", "148Nd", "Nd148", "148Sm", "Sm148",
    "149Sm", "Sm149", "150Nd", "Nd150", "151Eu", "Eu151", "152Sm", "Sm152",
    "153Eu", "Eu153", "154Sm", "Sm154", "155Gd", "Gd155", "156Gd", "Gd156",
    "157Gd", "Gd157", "158Gd", "Gd158", "159Tb", "Tb159", "160Gd", "Gd160",
    "161Dy", "Dy161", "162Dy", "Dy162", "163Dy", "Dy163", "164Dy", "Dy164",
    "165Ho", "Ho165", "166Er", "Er166", "167Er", "Er167", "168Er", "Er168",
    "169Tm", "Tm169", "170Er", "Er170", "171Yb", "Yb171", "172Yb", "Yb172",
    "173Yb", "Yb173", "174Yb", "Yb174", "175Lu", "Lu175", "176Yb", "Yb176",
    "209Bi", "Bi209"
  )
}

.removeMassFromDesc <- function(desc) {
  # Remove mass from channel descriptions.
  mass_str <- paste0("(", paste(.massSuspectValues(), collapse = "|"), ")")
  
  suspect_match <-
    unlist(lapply(desc, function(s) { grepl(mass_str, s) & grepl("_", s) }))
  if (sum(suspect_match) < 2) return(desc);
  
  # Try to remove them using regular expression.
  desc[suspect_match] <-
    unlist(lapply(desc[suspect_match], function(s) {
      s <- gsub(paste0("_", mass_str, "_"), "", s)
      s <- gsub(paste0(mass_str, "_"), "", s)
      s <- gsub(paste0("_", mass_str), "", s)
    }))
  
  # Check whether removal succeeded.
  suspect_match <-
    unlist(lapply(desc, function(s) { grepl(mass_str, s) & grepl("_", s) }))
  if (sum(suspect_match) >= 2) {
    stop("failed to remove masses from channel descriptions")
  }
  
  return(desc);
}

.removeEqFromDesc <- function(desc) {
  # Remove "EQ" suffix from channel descriptions.
  unlist(lapply(desc, function(s) gsub("_EQ", "", s)))
}

#' Import FCS Channel Information.
#'
#' Import the TEXT section of an FCS file and extract channel names and
#' descriptions (the $PnN and $PnS fields, respectively).
#'
#' @param filename The name of the FCS file to import.
#' @return A dataframe with channel names and descriptions.
#' @export
importFcsChannels <- function(filename) {
  fcs_text <- flowCore::read.FCSheader(filename)
  fcs_text <- fcs_text[[1]]

  n_parameters <- as.integer(fcs_text["$PAR"])
  name_keywords <- paste("$P", seq(n_parameters), "N", sep = "")
  desc_keywords <- paste("$P", seq(n_parameters), "S", sep = "")
  channels <- tibble::tibble(
    Name = fcs_text[name_keywords],
    Desc = fcs_text[desc_keywords]
  )

  # Convert NA description to empty string.
  channels$Desc[is.na(channels$Desc)] <- ""
  # Remove all non-alphanumeric characters from description.
  channels$Desc <- gsub("[^[:alnum:]]", "_", channels$Desc)
  
  # Remove masses and EQ suffix from channel descriptions.
  channels$Desc <- .removeMassFromDesc(channels$Desc)
  channels$Desc <- .removeEqFromDesc(channels$Desc)
  
  channels
}

#' Calculate parameter digest for sample.
#'
#' Apply the digest::digest function to the list of parameter descriptions and
#' parameter names for a given FCS data structure.
#'
#' @param sample An Astrolabe sample.
#' @param parameter_desc,parameter_name Parameter descriptions and names from
#' an FCS file.
#' @return Parameter digest for data.
#' @export
calculateFcsDigest <- function(sample, parameter_name = NULL) {
  if (is.null(parameter_name)) {
    # FCS data parameter.
    if (!isSample(sample)) stop("Expecting an Astrolabe sample")

    parameter_desc <- sample$parameter_desc
    parameter_name <- sample$parameter_name
  } else {
    # Parameters are explicit description and name.
    parameter_desc <- sample
  }

  digest::digest(list(desc = parameter_desc, name = parameter_name))
}

#' Import an FCS File.
#'
#' Imports an FCS file using flowCore::read.FCS and convert the flow_frame class
#' into orloj's internal FCS list format.
#'
#' The orloj FCS list format will accumulate more fields as analyses are
#' applied to it. For example, pre-processing will add a mask to find the
#' non-bead indices. You can use \code{\link{fcsExprs}} the get the expression
#' data after applying all of the masks that are in the list.
#'
#' @param filename The name of the FCS file to import.
#' @param transformation Which flowCore transformation to use. See
#' \code{\link[flowCore]{read.FCS}} for more information
#' @seealso \code{\link{isSample}}, \code{\link{fcsExprs}}
#' @return FCS data, in orloj internal FCS list format.
#' @export
importFcsFile <- function(filename,
                          transformation = "linearize") {
  # Import flow data and channels information.
  flow_frame <- flowCore::read.FCS(filename, transformation)
  channels <- importFcsChannels(filename)

  # Apply compensation if necessary.
  spill <- flowCore::keyword(flow_frame)$`SPILL`
  if (is.matrix(spill)) flow_frame <- flowCore::compensate(flow_frame, spill)

  exprs <- tibble::as_tibble(flow_frame@exprs)
  desc <- channels$Desc
  name <- channels$Name

  # Identify whether this is flow or mass cytometry data.
  source_flow_cytometry <-
    length(grep("FSC", name)) > 0 && length(grep("SSC", name)) > 0
  source_mass_cytometry <-
    length(grep("Ir191", name)) > 0 && length(grep("Ir193", name)) > 0
  if (source_flow_cytometry && source_mass_cytometry) {
    stop("FCS file source identified as both flow and mass cytometry")
  }
  if (!source_flow_cytometry && !source_mass_cytometry) {
    stop("cannot identify FCS file source")
  }
  source <- ""
  if (source_flow_cytometry) source <- "flow_cytometry"
  if (source_mass_cytometry) source <- "mass_cytometry"

  # Decide on column names, desc by default, if no desc use name.
  exprs_colnames <- desc
  exprs_colnames[is.na(exprs_colnames)] <- name[is.na(exprs_colnames)]
  exprs_colnames[exprs_colnames == ""] <- name[exprs_colnames == ""]
  # Duplicates get name in addition to desc.
  colnames_dup <-
    duplicated(exprs_colnames) | duplicated(exprs_colnames, fromLast = TRUE)
  exprs_colnames[colnames_dup] <-
    paste0(name[colnames_dup], "_", exprs_colnames[colnames_dup])
  colnames(exprs) <- exprs_colnames

  list(
    exprs = exprs,
    parameter_name = name,
    parameter_desc = desc,
    source = source
  )
}

#' Preprocess an Astrolabe sample.
#'
#' @param sample An Astrolabe sample.
#' @inheritParams massTransformMassChannels
#' @return Sample after the above steps are done.
#' @export
preprocess <- function(sample, cofactor = 5) {
  if (!isSample(sample)) stop("Expecting an Astrolabe sample")

  if (sample$source == "mass_cytometry") {
    massPreprocess(sample, cofactor)
  } else if (sample$source == "flow_cytometry") {
    flowPreprocess(sample)
  } else {
    stop("unknown sample source")
  }
}
