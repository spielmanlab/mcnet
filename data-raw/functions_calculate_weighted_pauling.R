## Functions used in parsing
TOL <- 6




count_elements <- function(med_data, water_standin, hydroxy_standin, ree_standin)
{
  
  
  ### Step 1: Remove all the irriting characters, and replace hydroxyl and ree standins  -----------------------------------------------------------------
  med_data %>% 
    # Remove trailing `(?)`, redox, [box], {, }, remove leading/trailing whitespace, and actually all spaces
    dplyr::mutate(chem = stringr::str_replace_all(chem, "\\(\\?\\) *$", ""), # (?)$
                  chem = stringr::str_replace_all(chem, "\\^[ \\d\\+-]+\\^",""), #redox
                  chem = stringr::str_replace_all(chem, "\\[box\\]", ""), # box
                  chem = stringr::str_replace_all(chem, "\\{", "("), # { --> (
                  chem = stringr::str_replace_all(chem, "\\}", ")"), # } --> )
                  chem = stringr::str_replace_all(chem, "\\[", "("), # [ --> (
                  chem = stringr::str_replace_all(chem, "\\]", ")"), # ) --> ]
                  # strip ends
                  chem = stringr::str_trim(chem, side = "both"),
                  # remove all spaces
                  chem = stringr::str_replace_all(chem, "\\s*", ""),
                  # Change all REE --> ree_standin
                  chem = stringr::str_replace_all(chem, "REE", ree_standin), 
                  ## !!! CHANGE ALL (OH) to hydroxy_standin !!!!! 
                  chem = stringr::str_replace_all(chem, "\\(OH\\)", hydroxy_standin), 
                  chem = stringr::str_replace_all(chem, "OH", hydroxy_standin)) -> med_cleaned



  ### Step 2: Subset to rows that we are NOT able to perform calculations for due to ambiguous formulas or is a known exclusion -----------------------------------------
  med_cleaned %>%
    dplyr::filter(#mineral_name %in% exclude | 
                  stringr::str_detect(chem, "~") |
                  stringr::str_detect(chem, "≈") |
                  stringr::str_detect(chem, "[^A-Z]x") | 
                  stringr::str_detect(chem, "[^A-Z]n") ) %>%
    dplyr::select(mineral_name, chem) -> med_ignore_temp 
  

  ### Step 3: Remove the `med_ignore_temp`, and clean the fractions/ranges to a single number -----------------------------------------
  med_cleaned %>%
    # Remove ambiguous rows for later
    dplyr::anti_join(med_ignore_temp) %>%
    # Clean the ranges and fractions 
    dplyr::mutate(chem = purrr::map(chem, replace_number_ranges_fractions)) %>%
    tidyr::unnest(cols = "chem") -> med_cleaned_rangefrac




  ### Step 4: Extract and save the amount of complexed waters for each mineral into `mineral_water_counts` ------------------------------------------------------
  med_cleaned_rangefrac %>% 
    dplyr::mutate(water_count = stringr::str_extract(chem, "·(\\d+\\.*\\d*)*\\(*H_2_O\\)*")) %>%
    tidyr::unnest(cols = "water_count") %>% 
    tidyr::replace_na(list(water_count = 0)) %>%
    dplyr::mutate(water_count = stringr::str_replace(water_count, "·", ""),
                  water_count = stringr::str_replace(water_count, "\\(*H_2_O\\)*", ""),
                  water_count = ifelse(water_count == "", 1, water_count)) %>%
    dplyr::mutate(water_count = as.numeric(water_count),
                  O = water_count,
                  H = water_count *2) %>%
    dplyr::select(-water_count, -chem) %>%
    tidyr::pivot_longer(O:H, names_to = "element", values_to = "count") -> mineral_water_counts

  # Remove complexed waters from mineral formulas, chuck every other · (they are not meaningful), AND change remaining waters to Bb
  med_cleaned_rangefrac %>%
    dplyr::mutate(chem = stringr::str_replace(chem, "·(\\d+\\.*\\d*)*\\(*H_2_O\\)*", ""),
                  chem = stringr::str_replace_all(chem, "·", ""),
                  chem = stringr::str_replace_all(chem, "H_2_O", water_standin)) -> med_cleaned_rangefrac_subwater
  

  ### Step 5: All parentheses get iteratively replaced with non-parentheses versions -----------------------------------------------
  full_counts <- tibble::tibble(element = as.character(),
                                count   = as.numeric(),
                                mineral_name = as.character())

  # back off my for loop, haters.
  for (min_name in sort(med_cleaned_rangefrac_subwater$mineral_name)){
  
    print(min_name)
    med_cleaned_rangefrac_subwater %>%
      dplyr::filter(mineral_name == min_name) %>%
      dplyr::pull(chem) -> pulled_chem

    if (stringr::str_count(pulled_chem, ",") > 0) pulled_chem <- clean_comma_parens(pulled_chem)
  
    # Replace all the regular parens
    pulled_chem %>%
      parse_all_paren() %>%
      parse_clean_formula() %>%
      dplyr::mutate(mineral_name = min_name) -> raw_counts

    # Return the hydroxy counts and immediately plop in with the full counts
    raw_counts %>% 
      dplyr::filter(element == hydroxy_standin) %>%
      dplyr::pull(count) -> hydroxy_count_raw
  
    if (length(hydroxy_count_raw) > 0) {
      final_hydroxy_count <- sum(hydroxy_count_raw)
      hydroxy_tibble <- tibble::tribble(~element, ~count, ~mineral_name, 
                                        "O", final_hydroxy_count, min_name, 
                                        "H", final_hydroxy_count, min_name)
      raw_counts %>%
        dplyr::filter(element != hydroxy_standin) %>%
        dplyr::bind_rows(hydroxy_tibble) -> raw_counts
    } 
    # And the water counts too
    raw_counts %>% 
      dplyr::filter(element == water_standin) %>%
      dplyr::pull(count) -> water_count_raw
  
    if (length(water_count_raw) > 0) {
      final_water_count <- sum(water_count_raw)
      water_tibble <- tibble::tribble(~element, ~count, ~mineral_name, 
                                        "O", final_water_count, min_name, 
                                        "H", final_water_count*2, min_name)
      raw_counts %>%
        dplyr::filter(element != water_standin) %>%
        dplyr::bind_rows(water_tibble) -> raw_counts
    
    } 
  
    ## Merge it up
    full_counts %>%
      dplyr::bind_rows(raw_counts) -> full_counts
  
  }


  ### Step 7: Tally all the counts into a single final tibble, AND CHECK IT ----------------------------
  full_counts %>%
    dplyr::bind_rows(mineral_water_counts) %>%
    dplyr::group_by(mineral_name, element) %>%
    dplyr::summarize(count = sum(count)) %>%
    dplyr::ungroup() %>%
    dplyr::filter(count > 0) %>%
    dplyr::distinct() %>%
    dplyr::mutate(element = ifelse(element == ree_standin, "REE", element)) %>%
    dplyr::arrange(mineral_name, element) -> final_counts_possible


  # RETURN
  list("counts" = final_counts_possible,
       "excluded" = med_ignore_temp)

}







divvy_standins <- function(chemform){
  # Turn things like Aa_0.5_ ----> O_0.25_H_0.25_
  
  total_amount <- as.numeric(stringr::str_split(chemform, "_")[[1]][2])
  new_chemform <- ""
  if (stringr::str_detect(chemform, hydroxy_standin))
  {
    new_chemform <- paste0("O_", total_amount,  "_H_", total_amount, "_")
  }
  else if (stringr::str_detect(chemform, water_standin))
  {
    new_chemform <- paste0("H_", 2*total_amount,  "_O_", total_amount, "_")
  }

  if(new_chemform == "") stop("Bad divvy standins")
  new_chemform
}

count_atoms <- function(chunk){
  matched_atoms <- stringr::str_match_all(chunk, "[A-Z][a-z]*_*\\d*\\.*\\d*_*")[[1]]
  total_atoms <- 0
  for (atom in matched_atoms){
    
    standin_multiplier <- 1
    # Check for a standin:
    if (stringr::str_count(atom,  hydroxy_standin) == 1) standin_multiplier <- 2
    if (stringr::str_count(atom, water_standin) == 1) standin_multiplier <- 3
    
    subscript <- as.numeric(stringr::str_match(atom, "_(\\d+\\.*\\d*)_")[,2])
    if (is.na(subscript)){
      total_atoms <- total_atoms + 1*standin_multiplier
    } else {
      total_atoms <- total_atoms + subscript*standin_multiplier
    }
    
  }
  total_atoms
}


# Convert the comma parentheses to real subscripts
clean_comma_parens <- function(chemform){
  
  #chemform <- "Na_12_(K,Sr,Ce)_3_Ca_6_Mn_3_Zr_3_NbSi_25_O_73_(O,Bb,Aa)_5_"
  #comma_chunks <- c("(NH_2_,K)")
  #comma_chunk <- "(NH_2_,K)"
  
  # If any parens, replace with count versions
  comma_chunks <- c(stringr::str_extract_all(chemform, "\\((\\w+,[\\w,]*)\\)" )[[1]],
                    stringr::str_extract_all(chemform, "\\((,[\\w,]*)\\)" )[[1]])

 # comma_chunk <- "(Aa,O)"
  for (comma_chunk in comma_chunks)
  {
    
    replacement <- ""

    # how many parts? eg, (H,K) is 2. (,F) is 1. (NH_2_,O) is 2.
    temp_chunk <- stringr::str_trim(stringr::str_replace_all(
                    stringr::str_replace_all(comma_chunk, "\\(", ""), "\\)", ""))
    # unique needed here also to not double count a repeat
    raw_n_parts <- unique( stringr::str_split(temp_chunk, ",")[[1]] )
    n_parts <- length(raw_n_parts[raw_n_parts != ""])
    # unique() takes care of things like (Mn,Mn) --> (Mn) ; (Mn,Mn,Fe) --> (Mn,Fe) 
    split_comma <- unique( stringr::str_split(temp_chunk, ",")[[1]] )
    

    for (chunk in split_comma){
      
      ## count number of atoms in the segment -------------------------------
      n_atoms <- count_atoms(chunk)

      #print(chunk)
      new_chunk <- parse_subset(chunk, (1/n_parts)/(n_atoms))
      
      if (stringr::str_detect(new_chunk, water_standin) | 
          stringr::str_detect(new_chunk, hydroxy_standin)) {
        new_chunk <- divvy_standins(new_chunk)
      }
      
      replacement <- paste0(replacement,
                            new_chunk)
      
    }
    chemform <- stringr::str_replace(chemform, comma_chunk, replacement)
  }
  
  chemform

}
# Find and replace all number ranges (1-3) and fractions (1/3) in a string. 
# Works with subscripts and multipliers (5-6Ca for example)
replace_number_ranges_fractions <- function(mineral_formula)
{
  # by NOT searching subscripts, we also get to deal with the waters. excellent
  present_ranges <- stringr::str_match_all(mineral_formula, "\\d+\\.*\\d*-\\d+\\.*\\d*")[[1]] # has [1], [2]x
  if (length(present_ranges) != 0){
    for (i in 1:length(present_ranges))
    {
      # to a character range, e.g. "_3-4_" --> "3-4"
      this_range <- stringr::str_replace_all(present_ranges[i], "_", "")
      # to separate numbers: "3-4" --> 3   4
      numbers_range <- as.numeric( stringr::str_split(this_range, "-")[[1]] )
      # Average those numbers
      final_count <- as.character( mean( numbers_range ) )
      
      
      # Now, replace the original subscript with this value
      # Issue of ambiguous replacement is ok, since this only does the FIRST occurrence, AND we are looping in order of occurrences. 
      # This will only replace the one we are at.
      # CAN'T BASE ON LOCATION since indices will change if we are replacing iteratively
      mineral_formula <- stringr::str_replace(mineral_formula, present_ranges[i], final_count)
    }
  }
  
  present_fractions <- stringr::str_match_all(mineral_formula, "\\d+\\.*\\d*/\\d+\\.*\\d*")[[1]] # has [1], [2]x
  if (length(present_fractions) != 0){
    for (i in 1:length(present_fractions))
    {
      # split on the / 
      num_den <- as.numeric( stringr::str_split(present_fractions[i], "/")[[1]] )
      # divide them
      final_count <- as.character( num_den[1] / num_den[2] )
      
      # Now, replace the original fraction with this value
      mineral_formula <- stringr::str_replace(mineral_formula, present_fractions[i], final_count)
    }
    
  }
  
  
  mineral_formula
}

parse_all_paren <- function(chemform){
  while (stringr::str_detect(chemform, "\\(")){
    chemform <- replace_individual_paren(chemform)
    #print(chemform)
    #print(stringr::str_detect(chemform, "\\("))
  }
  chemform
}


parse_subset <- function(formula_to_parse, multiplier)
{
  split_formula <- stringr::str_extract_all(formula_to_parse, "[A-Z][a-z]*_*[\\d\\.-]*_*")[[1]]
  # grab the subscripts themselves. 
  subscripts <- stringr::str_match_all(split_formula, "_([\\d\\.-]+)_")
  
  i <- 1
  replacement_formula <- ""
  for (element in split_formula){
    count <- ifelse( length(subscripts[[i]][,2]) == 0, 1, as.numeric(subscripts[[i]][,2]))
    
    replacement_formula <- paste0(replacement_formula, 
                                  stringr::str_replace(element, "_.+_", ""),
                                  "_", count * multiplier, "_")
    i <- i + 1
  }
  replacement_formula
  
}

replace_individual_paren <- function(chemform)
{
  # Only what is inside parentheses
  formula_to_parse <-  stringr::str_match(chemform, "\\(([\\w_\\d\\.-]+)\\)_*\\d*_*")[2]
  
  # The multiplier for that paren ---> UO_2
  full_match <- stringr::str_match(chemform, "\\([\\w_\\d\\.-]+\\)_*(\\d*)_*")
  original_formula <- stringr::str_match(chemform, "\\([\\w_\\d\\.-]+\\)_*(\\d*)_*")[1]
  original_formula <- stringr::str_replace(
    stringr::str_replace(original_formula, "\\(", "\\\\("),
    "\\)", "\\\\)")
  
  multiplier <- as.numeric(full_match[2])
  if (is.na(multiplier)) multiplier <- 1
  ## --> multiplier is 3
  
  replacement_formula <- parse_subset(formula_to_parse, multiplier)
 
  chemform <- stringr::str_replace(chemform, 
                                   original_formula, 
                                   replacement_formula)
  chemform
}


parse_clean_formula <- function(formula_to_parse)
{
  # formula_to_parse = the formula to parse ALREADY CLEANED OF ALL PARENTHESES
  formula_tibble <- tibble::tibble(element      = as.character(),
                                   count        = as.numeric())

  # Split into elements and associated subscripts
  split_formula <- stringr::str_extract_all(formula_to_parse, "[A-Z][a-z]*_*[\\d\\.-]*_*")[[1]]
  # grab the subscripts themselves.
  subscripts <- stringr::str_match_all(split_formula, "_([\\d\\.-]+)_")

  i <- 1
  for (element in split_formula){
    element_count <- ifelse( length(subscripts[[i]][,2]) == 0, 1, as.numeric(subscripts[[i]][,2]))
    dplyr::bind_rows(formula_tibble,
                     tibble::tibble(element = stringr::str_replace(element, "_.+_", ""),
                                    count   = element_count)
    ) -> formula_tibble
    i <- i + 1
  }
  formula_tibble
}


calculate_weighted_values <- function(df, pauling_values)
{
  
  df %>%
    dplyr::left_join(pauling_values, by = "element") -> calc_electro_data
  
  weighted_pauling<- tibble::tibble(mineral_name = as.character(),
                                    w_mean_pauling = as.numeric(),
                                    w_cov_pauling   = as.numeric())
  
  for (min_name in unique(calc_electro_data$mineral_name)){
    print(min_name)
    all_paulings <- c()
    calc_electro_data %>% 
      dplyr::filter(mineral_name == min_name) -> min_only 
    for (el in unique(min_only$element)){
      min_el_only <- min_only %>% dplyr::filter(element == el)
      all_paulings <- c(all_paulings, rep(min_el_only$pauling, min_el_only$count))
    }
    weighted_pauling <- dplyr::bind_rows(weighted_pauling, 
                                         tibble::tibble(mineral_name = min_name,
                                                        w_mean_pauling = mean(all_paulings),
                                                        w_cov_pauling   = sd(all_paulings)/w_mean_pauling))
  }
  
  weighted_pauling
}



## Function to change specific formulas observed to need manual tweaks
apply_manual_formula_changes <- function(df)
{
  df %>%
    dplyr::mutate(chem = dplyr::case_when(mineral_name == "Ammineite"         ~ "CuCl_2_(NH_3_)_2_", # Had missing parentheses in IMA
                                          mineral_name == "Byzantievite"      ~ "Ba_5_(Ca,REE,Y)_22_(Ti,Nb)_18_(SiO_4_)_4_(P_4_O_16_,Si_4_O_16_)B_9_O_27_O_22_((OH),F)_43_(H_2_O)_1.5_", # Ba_5_(Ca,REE,Y)_22_(Ti,Nb)_18_(SiO_4_)_4_[(PO_4_),(SiO_4_)]_4_(BO_3_)_9_O_22_[(OH),F]_43_(H_2_O)_1.5_
                                          mineral_name == "Kolitschite"       ~ "PbZnFe_3_(AsO_4_)_2_(OH)_6_", # HALF ZN, HALF UNKNOWN= CALC AS 100% ZN:  Pb[Zn_0.5_,[box]_0.5_]Fe_3_(AsO_4_)_2_(OH)_6_ ; has 0.5[box] so this is the mindat match.
                                          mineral_name == "Vladimirivanovite" ~ "Na_6_Ca_2_Al_6_Si_6_O_24_(S_2_O_8_,S_6_,S_4_,Cl_2_)(H_2_O)", #Na_6_Ca_2_[Al_6_Si_6_O_24_](SO_4_,S_3_,S_2_,Cl)_2_·H_2_O
                                          mineral_name == "Uranospathite"     ~ "(Al,[box])(U^6+^O_2_)_2_F(PO_4_)_2_(H_2_O,F)_20_", # (Al,[box])(U^6+^O_2_)_2_F(PO_4_)_2_·20(H_2_O,F)
                                          mineral_name == "Vinogradovite"     ~ "Na_4_Ti_4_(Si_2_O_6_)_2_(Si,Al)_4_O_10_O_4_(H_2_O,Na,K)_3_", # Na_4_Ti_4_(Si_2_O_6_)_2_[(Si,Al)_4_O_10_]O_4_·(H_2_O,Na,K)_3_ 
                                          mineral_name == "Clinotobermorite"  ~ "Ca_5_Si_6_O_17_5H_2_O",
                                          mineral_name == "Tobermorite"       ~ "Ca_5_Si_6_O_17_(H_2_O)_2_(H_2_O)_3_", 
                                          mineral_name == "Plombierite"       ~ "Ca_5_Si_6_O_16_(OH)_2_(H_2_O)_7_", 
                                          # scalars
                                          mineral_name == "Ferrovalleriite" ~ "(Fe,Cu)_2_S_2_(Fe^2+^,Al,Mg)_1.53_(OH)_3.06_", #2(Fe,Cu)S·1.53[(Fe^2+^,Al,Mg)(OH)_2_]  # I THINK FORMULA IS WRONG AND SHOULD HAVE BRACES AROUND (Fe,Cu)S !!!
                                          mineral_name == "Haapalaite"      ~ "(Fe^2+^,Ni^2+^)_2_S^2-^_2_(Mg,Fe^2+^)_1.61_(OH)_3.22_", #2[(Fe^2+^,Ni^2+^)S^2-^]·1.61[(Mg,Fe^2+^)(OH)_2_]
                                          mineral_name == "Metakottigite"   ~ "(Zn,Fe^3+^)_3_(AsO_4_)_2_(H_2_O,OH)_8_",               # (Zn,Fe^3+^)_3_(AsO_4_)_2_·8(H_2_O,OH), having the h20/oh in same place means kill the scalar
                                          mineral_name == "Tochilinite"     ~ "(Fe^2+^_0.9_S^2-^)_6_(Mg,Fe^2+^)_5_(OH)_10_",      #6(Fe^2+^_0.9_S^2-^)·5[(Mg,Fe^2+^)(OH)_2_] 
                                          mineral_name == "Valleriite"      ~ "(Fe,Cu)_2_S_2_(Mg,Al)_1.53_(OH)_3.06_",            # 2[(Fe,Cu)S]·1.53[(Mg,Al)(OH)_2_]) 
                                          TRUE                              ~ chem)) 
}







