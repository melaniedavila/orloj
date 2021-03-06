#' Differential abundance analysis report.
#'
#' Generate plots and CSV files that report on differential abundance analysis
#' over multiple samples, sample features, and cell subsets. For each sample
#' feature, the report includes box plots, bar plots, line plots, and volcano
#' plot of analysis results.
#'
#' @param experiment An Astrolabe experiment.
#' @import ggplot2
#' @export
reportDifferentialAbundanceAnalysis <- function(experiment) {
  samples <- experiment$samples
  features <- experiment$features
  sample_features <- experiment$sample_features

  # Load aggregate statistics and differential abundance analysis.
  aggregate_statistics_filename <-
    file.path(experiment$analysis_path, "combine_aggregate_statistics.RDS")
  if (!file.exists(aggregate_statistics_filename)) {
    stop(paste0("unable to find ", aggregate_statistics_filename))
  }
  aggregate_statistics <- readRDS(aggregate_statistics_filename)

  daa_filename <-
    file.path(experiment$analysis_path, "differential_abundance_analysis.RDS")
  if (!file.exists(daa_filename)) {
    stop(paste0("unable to find ", daa_filename))
  }
  differential_abundance_analysis <- readRDS(daa_filename)
  # Get group feature label + name.
  group_feature_label <- differential_abundance_analysis$group_feature_label
  if (!is.null(group_feature_label)) {
    group_feature_name <-
      dplyr::filter(experiment$features,
                    FeatureId == gsub("feature_", "",
                                      group_feature_label))$FeatureName
  }

  analyses <-
    names(differential_abundance_analysis$differential_abundance_analysis)
  lapply(nameVector(analyses), function(analysis) {
    cell_counts <- getCellCounts(aggregate_statistics, analysis)
    group_feature_label <- differential_abundance_analysis$group_feature_label
    daa <-
      differential_abundance_analysis$differential_abundance_analysis[[analysis]]

    # Get DAA in export-ready format.
    export_daa <- differentialAbundanceAnalysis(experiment, level = analysis)

    # Join data with sample name and sample features.
    figure_data <- cell_counts %>%
      dplyr::left_join(sample_features, by = "SampleId") %>%
      dplyr::left_join(samples, by = "SampleId") %>%
      dplyr::rename(SampleName = Name)
    # Calculate frequencies.
    figure_data <- figure_data %>%
      dplyr::group_by(SampleId) %>%
      dplyr::mutate(Frequency = N / sum(N)) %>%
      dplyr::ungroup()

    # Generate figures for each feature separately.
    feature_names <- features$FeatureName
    lapply(nameVector(feature_names), function(feature_name) {
      feature_r_name <-
        paste0(
          "feature_",
          dplyr::filter(features, FeatureName == feature_name)$FeatureId
        )
      feature_report <- list()

      # Get analysis results for this feature.
      feature_top_tags <- daa[[feature_r_name]]$table
      if (is.null(feature_top_tags)) {
        return(feature_top_tags);
      }
      feature_top_tags <-
        tibble::rownames_to_column(feature_top_tags, "CellSubset")
      cell_subset_labels <- feature_top_tags$CellSubset

      # Whether to include line plots: sample has a grouping feature, and that
      # feature varies across current feature.
      include_line_plots <- FALSE
      if (!is.null(group_feature_label)) {
        feature_pairs <-
          unique(figure_data[, c(feature_r_name, group_feature_label)])
        include_line_plots <-
          nrow(feature_pairs) >
          length(unique(figure_data[[group_feature_label]]))
      }

      # Table: Result of differential analysis.
      feature_report[["analysis_results"]] <-
        list(data = export_daa[[feature_name]])

      # Figure: Volcano plot
      feature_top_tags$negLog10Fdr = -log10(feature_top_tags$FDR)
      if ("logFC" %in% colnames(feature_top_tags)) {
        volcano_plot_x <- "logFC"
      } else if ("maxLogFc" %in% colnames(feature_top_tags)) {
        volcano_plot_x <- "maxLogFc"
      } else {
        stop("feature_top_tags does not include logFC or maxLogFc")
      }
      volcano_plt_list <-
        plotScatterPlot(feature_top_tags,
                        x = volcano_plot_x,
                        y = "negLog10Fdr")
      volcano_plt_list$plt <- volcano_plt_list$plt +
        ggrepel::geom_text_repel(aes(label = CellSubset))
      feature_report[["volcano"]] <- volcano_plt_list

      # Figures: Line plots (for non-patient features in experiments that have
      # patient), box plots, and bar plots.
      feature_report[["box_plots"]] <- list()
      feature_report[["bar_plots"]] <- list()
      if (include_line_plots) feature_report[["line_plots"]] <- list()

      for (cell_subset_label in cell_subset_labels) {
        # Filter data down to this subset.
        cell_subset_data <-
          dplyr::filter(figure_data, CellSubset == cell_subset_label)

        # Format FDR nicely for figure title.
        fdr <-
          dplyr::filter(feature_top_tags, CellSubset == cell_subset_label)$FDR
        fdr_str <- paste0("(", formatPvalue(fdr, "FDR"), ")")
        fig_title <- paste0(cell_subset_label, " ", fdr_str)

        # Generate box plot.
        box_plot <-
          plotBoxPlot(cell_subset_data,
                      x = feature_r_name,
                      y = "Frequency",
                      title = fig_title,
                      scale_y_labels = scales::percent)
        box_plot$plt <- box_plot$plt + xlab(feature_name)
        feature_report[["box_plots"]][[cell_subset_label]] <- box_plot

        # Generate bar plot.
        sample_order <- dplyr::arrange(cell_subset_data, Frequency)$SampleName
        cell_subset_data$SampleName <-
          factor(cell_subset_data$SampleName, levels = sample_order)
        bar_plot <-
          plotBarPlot(cell_subset_data,
                      x = "SampleName",
                      y = "Frequency",
                      fill = feature_r_name,
                      title = fig_title,
                      scale_y_labels = scales::percent)
        feature_report[["bar_plots"]][[cell_subset_label]] <- bar_plot

        # Generate line plot, using the box_plot parameters as base.
        if (include_line_plots) {
          # Copy height/width from box plot.
          line_plot <- box_plot
          # Reorganize data.
          line_plot_data <- cell_subset_data %>%
            dplyr::group_by_(group_feature_label, feature_r_name) %>%
            dplyr::summarize(Frequency = median(Frequency))
          # Subset data for labels.
          label_data <- line_plot_data
          last_value <- tail(unique(line_plot_data[[feature_r_name]]), 1)
          label_data <- label_data[label_data[[feature_r_name]] == last_value, ]
          
          line_plot$plt <-
            ggplot(line_plot_data,
                   aes_string(x = feature_r_name, y = "Frequency")) +
            geom_line(aes_string(group = group_feature_label)) +
            geom_text(data = label_data,
                      aes_string(x = Inf,
                                 label = group_feature_label),
                      hjust = 2) +
            scale_y_continuous(labels = scales::percent) +
            labs(title = fig_title, x = feature_name)
          # Update the data with a table of values by group variable.
          line_plot$data <-
            reshape2::dcast(
              line_plot_data,
              as.formula(paste0(group_feature_label, " ~ ", feature_r_name)),
              value.var = "Frequency"
            )
          colnames(line_plot$data)[1] <- group_feature_name
          
          feature_report[["line_plots"]][[cell_subset_label]] <- line_plot
        }
      }

      feature_report
    })
  })
}
