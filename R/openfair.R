#' Given a number of loss events and a loss distribution, calculate losses
#'
#' @importFrom stats median
#' @param n Numer of threat events to evaluate
#' @param l Low boundary
#' @param ml Most likely
#' @param h High boundary
#' @param conf Confidence
#' @return List of total loss, min/max/mean of sle
sample_lm <- function(n, l, ml, h, conf) {

    if (is.na(n)) { n <- 0 }
    samples <- mc2d::rpert(n, l, ml, h, shape = conf)

    # We have to calculate ALE/SLE differently (ALE: 0, SLE: NA) if there are no losses
    results <- if (length(samples) == 0) {
        list(ale = 0, sle_max = 0, sle_min = 0, sle_mean = 0, sle_median = 0)
    } else {
        list(ale = sum(samples),
             sle_max = max(samples),
             sle_min = min(samples[samples > 0]),
             sle_mean = mean(samples[samples > 0]),
             sle_median = median(samples[samples > 0])
             )
    }

    return(results)
}

#' Calculate the threat capability and whether the control(s) resist the attack
#'
#' @import dplyr
#' @param n Number of threat events to evaluate
#' @param TCestimate Threat capability estimate - df(l, m, h, conf)
#' @param DIFFsamples Pre-sampled
#' @param DIFFestimate Control difficulty estimate - df(l, m, h, conf)
#' @param verbose A boolean
#' @return List of number of successful attacks (i.e. loss events),
#'   mean tc exceedance (how much TC > DIFF), and mean diff exceedance
#'   (how much DIFF > TC)
select_events <- function(n, TCestimate, DIFFsamples = NULL, DIFFestimate = NULL, verbose = FALSE) {

    if (verbose) message(paste("Sampling:", "n:", n, "TCestimate", TCestimate, "DIFFestimate", DIFFestimate))

    # if there are no threat events to select from, then return NAs
    if (n == 0) {
        return(list(loss_events = 0, mean_tc_exceedance = 0, mean_diff_exceedance = 0))
    }

    # sample threat capability
    TCsamples <- mc2d::rpert(n, TCestimate$l, TCestimate$ml, TCestimate$h, shape = TCestimate$conf)

    # sample difficulty, either by sampling from a precomputed vector or from a list of probability distributions
    if (is.null(DIFFsamples)) {
        DIFFsamples <- mapply(function(l, ml, h, conf) {
            mc2d::rpert(n, l, ml, h, conf)
        }, DIFFestimate$l, DIFFestimate$ml, DIFFestimate$h, DIFFestimate$conf)
        # if we were supplied an array of controls, take the mean for the effective control strength across the scenario
        DIFFsamples <- if (is.array(DIFFsamples)) { rowMeans(DIFFsamples)
          } else {
            mean(DIFFsamples)
        }
    } else {
        DIFFsamples <- DIFFsamples[1:n]
    }

    # loss events occur whenever TC > DIFF
    VULNsamples <- TCsamples > DIFFsamples

    # TC exceedance is TC - DIFF - how much more capable the threat actor is vs. the capability defending against it
    mean_tc_exceedance <- mean(TCsamples[VULNsamples == TRUE] - DIFFsamples[VULNsamples], na.rm = TRUE)
    if (is.nan(mean_tc_exceedance))
        mean_tc_exceedance <- 0

    # DIFF exceedance is DIFF - TC - how much more capable the capability set is vs. the threat acting against it
    mean_diff_exceedance <- mean(DIFFsamples[VULNsamples == FALSE] - TCsamples[VULNsamples == FALSE], na.rm = TRUE)
    if (is.nan(mean_diff_exceedance))
        mean_diff_exceedance <- 0

    return(list(loss_events = length(VULNsamples[VULNsamples == TRUE]), mean_tc_exceedance = mean_tc_exceedance, mean_diff_exceedance = mean_diff_exceedance))
}

#' Run an OpenFAIR simulation
#'
#' @import dplyr
#' @importFrom purrr map_df
#' @param scenario list of tef_, tc_, and LM_ l/ml/h/conf parameters
#' @param diff_samples Sampled difficulties for the scenario (DEPRECATED)
#' @param diff_estimates Sampled difficulties for the scenario
#' @param n Number of simulations to run
#' @param title Optional name of scenario
#' @param verbose Whether to print progress indicators
#' @return Dataframe of scenario name, threat_events count, loss_events count,
#'   mean TC and DIFF exceedance, and ALE samples
#' @export
calculate_ale <- function(scenario, diff_samples = NULL, diff_estimates = NULL, n = 10^4, title = "Untitled", verbose = FALSE) {

    # make samples repeatable (and l33t)
    set.seed(31337)

    if (verbose) {
        message("Working on scenario ", title)
        message(paste("Scenario is: ", scenario[, -which(names(scenario) %in% "diff_samples")], "\n"))
        # message(paste('Names are ', names(scenario)))
    }

    # get parameters for TEF, LC, and LM calibrated estimates
    TEFestimate <- data.frame(l = scenario$tef_l, ml = scenario$tef_ml, h = scenario$tef_h, conf = scenario$tef_conf)
    TCestimate <- data.frame(l = scenario$tc_l, ml = scenario$tc_ml, h = scenario$tc_h, conf = scenario$tc_conf)
    LMestimate <- data.frame(l = scenario$lm_l, ml = scenario$lm_ml, h = scenario$lm_h, conf = scenario$lm_conf)

    # we need estimates for DIFF or, less optimally, pre-sampled DIFFs
    if (is.null(diff_samples) && is.null(diff_estimates)) {
        stop("Must supply either diff_samples or diff_estimates")
    } else if (!is.null(diff_samples) && !is.null(diff_estimates)) {
        stop("Cannot supply both diff_samples and diff_estimates")
    }
    if (is.null(diff_samples)) {
        # DIFFestimate <- data.frame(l = scenario$diff_ml, ml = scenario$diff_ml, h = scenario$diff_h, conf = scenario$diff_conf)
        DIFFestimate <- diff_estimates
    }

    # TEF - how many contacts do we have in each simulated year
    TEFsamples <- mc2d::rpert(n, TEFestimate$l, TEFestimate$ml, TEFestimate$h, shape = TEFestimate$conf)
    # fractional events per year is nonsensical, so round to the nearest integer
    TEFsamples <- round(TEFsamples)

    # for each threat contact (TEF), calculate how many succeed (become LEF
    # counts) LEF contains: #er of threat events, # of times system is vuln
    if (is.null(diff_samples)) {
        results <- lapply(TEFsamples, function(x) select_events(x, TCestimate, DIFFestimate = DIFFestimate))
    } else {
        results <- lapply(TEFsamples, function(x) select_events(x, TCestimate, DIFFsamples = diff_samples))
    }
    LEF <- unlist(results)[attr(unlist(results), "names") == "loss_events"]
    mean_tc_exceedance <- unlist(results)[attr(unlist(results), "names") == "mean_tc_exceedance"]
    mean_diff_exceedance <- unlist(results)[attr(unlist(results), "names") == "mean_diff_exceedance"]


    # for the range of loss events, calculate the annual sum of losses across the range of possible LMs
    loss_samples <- map_df(unname(LEF), function(x) sample_lm(x, l = LMestimate$l,
                                                              ml = LMestimate$ml,
                                                              h = LMestimate$h,
                                                              conf = LMestimate$conf))
    loss_samples <- bind_rows(loss_samples)

    # summary stats for ALE
    if (verbose) {
        print(summary(loss_samples$ale))
        value_at_risk <- quantile(loss_samples$ale, probs = (0.95))
        message(paste0("Losses at 95th percentile are $",
                       format(value_at_risk, nsmall = 2, big.mark = ",")))
    }

    simulation_results <- tibble::data_frame(title = rep(as.character(title), n),
                                             simulation = seq(1:n),
                                             threat_events = TEFsamples,
                                             loss_events = LEF,
                                             mean_tc_exceedance = mean_tc_exceedance,
                                             mean_diff_exceedance = mean_diff_exceedance,
                                             ale = loss_samples$ale,
                                             sle_max = loss_samples$sle_max,
                                             sle_min = loss_samples$sle_min,
                                             sle_mean = loss_samples$sle_mean,
                                             sle_median = loss_samples$sle_median)

    return(simulation_results)
}
