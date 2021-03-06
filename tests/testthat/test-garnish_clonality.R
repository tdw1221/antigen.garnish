testthat::test_that("garnish_clonality", {

  # load test data
  d <- test_data_dir()

    dt <- file.path(d, "antigen.garnish_PureCN_example_output.txt") %>%
              data.table::fread() %>%
              .[, c("cl_proportion", "clone_id") := NULL]
  # run test

  dto <-  dt %>% garnish_clonality

  testthat::expect_equal(dto[, clone_id %>% as.numeric %>%
                         range(na.rm = TRUE)], c(1,2))
  testthat::expect_equal(dto[!is.na(cl_proportion), cl_proportion %>%
                         range(na.rm = TRUE)], c(0.2720, 0.7764))

# now check AF instead of CF


dt %>% data.table::setnames("cellular_fraction", "allelic_fraction")

dt %<>% garnish_clonality

testthat::expect_equal(dt[, clone_id %>% as.numeric %>%
                       range(na.rm = TRUE)],
                       c(1,2))
testthat::expect_equal(dt[!is.na(cl_proportion),
                       cl_proportion %>% range(na.rm = TRUE)] %>%
                       signif(digits = 3), c(0.259, 0.741))

    })
