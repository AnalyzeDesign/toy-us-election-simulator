rm(list=ls())
library(tidyverse)
library(lubridate)
library(politicaldata)
library(pbapply)
library(parallel)

setwd('~/Desktop')

# weights
states2016 <- read_csv('2016.csv') %>%
  mutate(score = clinton_count / (clinton_count + trump_count),
         national_score = sum(clinton_count)/sum(clinton_count + trump_count),
         delta = score - national_score,
         share_national_vote = (total_count*(1+adult_pop_growth_2011_15))
         /sum(total_count*(1+adult_pop_growth_2011_15))) %>%
  arrange(state) 

state_weights <- c(states2016$share_national_vote / sum(states2016$share_national_vote))
names(state_weights) <- states2016$state

# read in the polls
all_polls <- read_csv('polls.csv')

# remove any polls if biden or trump blank
all_polls <- all_polls %>% filter(!is.na(biden),!is.na(trump))#, include == "TRUE")

regression_weight <- 
  sqrt((all_polls %>% filter(state != '--') %>% pull(number.of.observations) %>% mean) / 
         (all_polls %>% filter(state != '--') %>% pull(number.of.observations) %>% mean))

all_polls <- all_polls %>%
  filter(mdy(end.date) >= (Sys.Date()-60) ) %>%
  mutate(weight = sqrt(number.of.observations / mean(number.of.observations)))

national_biden_margin <- all_polls %>%
  filter(state == '--',
         grepl('phone',tolower(mode))) %>%
  summarise(mean_biden_margin = weighted.mean(biden-trump,weight)) %>%
  pull(mean_biden_margin)/100

state_averages <- all_polls %>%
  filter(state != '--') %>%
  group_by(state) %>%
  summarise(mean_biden_margin = weighted.mean(biden-trump,weight)/100,
            num_polls = n(),
            sum_weights = sum(weight,na.rm=T))

# make projection in states without polls
results <- politicaldata::pres_results %>% 
  filter(year == 2016) %>%
  mutate(clinton_margin = dem-rep) %>%
  select(state,clinton_margin)

# coefs for a simple model
coefs <- read_csv('coefs.csv')

# bind everything together
state <- results %>%
  left_join(state_averages) %>%
  mutate(dem_lean_2016 = clinton_margin - 0.021,
         dem_lean_2020_polls = mean_biden_margin - national_biden_margin) %>%
  left_join(coefs)

# train a model
model <- lm(mean_biden_margin ~ 
              clinton_margin + 
              log(pop_density) +
              wwc_pct,
   data = state,
   weight=sum_weights)

summary(model)

# make the projections
state <- state %>%
  mutate(sum_weights = ifelse(is.na(sum_weights),0,sum_weights),
         mean_biden_margin = ifelse(is.na(mean_biden_margin),999,mean_biden_margin),
         proj_mean_biden_margin = predict(model,.)) %>%
  mutate(mean_biden_margin_hat = #proj_mean_biden_margin
           (mean_biden_margin * (sum_weights/(sum_weights+regression_weight)) ) +
           (proj_mean_biden_margin * (regression_weight/(sum_weights+regression_weight)) )
) %>%
  mutate(mean_biden_margin = ifelse(mean_biden_margin==999,NA,mean_biden_margin))

ggplot(state, aes(mean_biden_margin, mean_biden_margin_hat,label=state)) +
  geom_text(aes(size=num_polls)) + 
  geom_abline() + 
  geom_smooth(method='lm')

adj_national_biden_margin = national_biden_margin#weighted.mean(state$mean_biden_margin_hat,state_weights)

state$dem_lean_2020 =  state$mean_biden_margin_hat - adj_national_biden_margin 

national_biden_margin = adj_national_biden_margin

# clean
final <- state %>%
  select(state,clinton_margin,dem_lean_2016,
         mean_biden_margin = mean_biden_margin_hat,
         dem_lean_2020_polls,
         dem_lean_2020, 
         num_polls) %>%
  mutate(shift = dem_lean_2020 - dem_lean_2016)

final <- final %>%
  left_join(read_csv('state_evs.csv')) %>%
  left_join(read_csv('state_region_crosswalk.csv') %>% 
              dplyr::select(state=state_abb,region))

final %>% 
  filter(abs(clinton_margin) < 0.1) %>% # num_polls > 0
  ggplot(., aes(y=reorder(state,shift),x=shift,
                col = clinton_margin > 0)) + 
  #geom_point() +
  geom_vline(xintercept = 0) + 
  geom_label(aes(label = state,size=ev)) +
  scale_size(range=c(2,6)) + 
  scale_x_continuous(breaks=seq(-1,1,0.01),
                     labels = function(x){round(x*100)}) +
  scale_color_manual(values=c('TRUE'='blue','FALSE'='red')) +
  theme_minimal() + 
  theme(panel.grid.minor = element_blank(),
        legend.position = 'none',
        axis.text.y=element_blank(),
        axis.title.y=element_blank(),
        axis.ticks.y=element_blank()) +
  labs(subtitle='Swing toward Democrats in relative Democratic vote margin\nSized by electoral votes',
       x='Biden state margin relative to national margin\nminus Clinton state margin relative to national margin')


# tipping point state
final %>%
  arrange(desc(mean_biden_margin)) %>%
  mutate(cumulative_ev = cumsum(ev)) %>%
  filter(cumulative_ev >= 270) # %>% filter(row_number() == 1) 


# toy simulations ---------------------------------------------------------
# errors
national_error <- (0.0167*2)*1.5
regional_error <- (0.0167*2)*1.5
state_error <- (0.0152*2)*1.5

# sims
national_errors <- rnorm(1e04, 0, national_error)
regional_errors <- replicate(1e04,rnorm(length(unique(final$region)), 0, regional_error))
state_errors <- replicate(1e04,rnorm(51, 0, state_error))

# actual sims
state_and_national_errors <- pblapply(1:length(national_errors),
                                      cl = detectCores() -1,
                                      function(x){
                                        state_region <- final %>%
                                          mutate(proj_biden_margin = dem_lean_2020 + national_biden_margin) %>%
                                          select(state, proj_biden_margin) %>%
                                          left_join(final %>% 
                                                      ungroup() %>%
                                                      dplyr::select(state,region) %>% distinct) %>%
                                          left_join(tibble(region = unique(final$region),
                                                           regional_error = regional_errors[,x])) %>%
                                          left_join(tibble(state = unique(final$state),
                                                           state_error = state_errors[,x]))
                                        
                                        state_region %>%
                                          mutate(error = state_error + regional_error + national_errors[x]) %>% 
                                          mutate(sim_biden_margin = proj_biden_margin + error) %>%
                                          dplyr::select(state,sim_biden_margin)
                                      })
# check the standard deviation (now in margin)
state_and_national_errors %>%
  do.call('bind_rows',.) %>%
  group_by(state) %>%
  summarise(sd = sd(sim_biden_margin)) %>% 
  pull(sd) %>% mean
  

# calc the new tipping point
tipping_point <- state_and_national_errors %>%
  do.call('bind_rows',.) %>%
  group_by(state) %>%
  mutate(draw = row_number()) %>%
  ungroup() %>%
  left_join(states2016 %>% dplyr::select(state,ev),by='state') %>%
  left_join(enframe(state_weights,'state','weight')) %>%
  group_by(draw) %>%
  mutate(dem_nat_pop_margin = weighted.mean(sim_biden_margin,weight))


tipping_point <- pblapply(1:max(tipping_point$draw),
                          cl = parallel::detectCores() - 1,
                          function(x){
                            temp <- tipping_point[tipping_point$draw==x,]
                            
                            if(temp$dem_nat_pop_margin > 0){
                              temp <- temp %>% arrange(desc(sim_biden_margin))
                            }else{
                              temp <- temp %>% arrange(sim_biden_margin)
                            }
                            
                            return(temp)
                          }) %>%
  do.call('bind_rows',.)

# what is the tipping point
tipping_point %>%
  mutate(cumulative_ev = cumsum(ev)) %>%
  filter(cumulative_ev >= 270) %>%
  filter(row_number() == 1) %>% 
  group_by(state) %>%
  summarise(prop = n()) %>%
  mutate(prop = prop / sum(prop)) %>%
  arrange(desc(prop))

# ev-popvote divide?
tipping_point %>%
  mutate(cumulative_ev = cumsum(ev)) %>%
  filter(cumulative_ev >= 270) %>%
  filter(row_number() == 1)  %>%
  mutate(diff = dem_nat_pop_margin - sim_biden_margin) %>%
  pull(diff) %>% mean # hist(breaks=100)


# graph mean estimate
urbnmapr::states %>%
  left_join(tipping_point %>%
              group_by(state_abbv = state) %>%
              summarise(mean_biden_margin = mean(sim_biden_margin,na.rm=T),
                        ev = unique(ev),
                        prob = mean(sim_biden_margin > 0,na.rm=T)) %>%
              ungroup() %>%
              mutate(mean_biden_margin = case_when(mean_biden_margin > 0.2 ~ 0.2,
                                                   mean_biden_margin < -0.2 ~ -0.2,
                                                   TRUE ~ mean_biden_margin)) %>%
              arrange(desc(mean_biden_margin)) %>% 
              mutate(cumulative_ev = cumsum(ev)) ) %>%
  ggplot(aes(x=long,y=lat,group=group,fill=mean_biden_margin*100)) +
  geom_polygon(col='gray40')  + 
  coord_map("albers",lat0=39, lat1=45) +
  scale_fill_gradient2(name='Democratic vote margin',high='#3498DB',low='#E74C3C',mid='gray98',midpoint=0,
                       limits = c(-20,20)) +
  theme_void() + 
  theme(legend.position = 'top')


# graph win probabilities
urbnmapr::states %>%
  left_join(tipping_point %>%
              group_by(state_abbv = state) %>%
              summarise(mean_biden_margin = mean(sim_biden_margin,na.rm=T),
                        ev = unique(ev),
                        prob = mean(sim_biden_margin > 0,na.rm=T)) %>%
              arrange(desc(mean_biden_margin)) %>% 
              mutate(cumulative_ev = cumsum(ev)) ) %>%
  ggplot(aes(x=long,y=lat,group=group,fill=prob*100)) +
  geom_polygon(col='gray40')  + 
  coord_map("albers",lat0=39, lat1=45) +
  scale_fill_gradient2(name='Democratic win probability',high='#3498DB',low='#E74C3C',mid='gray98',midpoint=50,
                       limits = c(0,100)) +
  theme_void() + 
  theme(legend.position = 'top')


# electoral vote histogram
tipping_point %>%
  group_by(draw) %>%
  summarise(dem_ev = sum(ev * (sim_biden_margin > 0))) %>%
  ggplot(.,aes(x=dem_ev,fill=dem_ev >= 270)) +
  geom_histogram(binwidth=1) + 
  scale_fill_manual(values=c('TRUE'='blue','FALSE'='red')) +
  scale_y_continuous(labels = function(x){paste0(round(x / max(tipping_point$draw)*100,2),'%')}) +
  labs(x='Democratic electoral votes',y='Probability') +
  theme_minimal() + 
  theme(legend.position = 'none')  +
  coord_cartesian(ylim=c(0,150))

# prob?
tipping_point %>%
  group_by(draw) %>%
  summarise(dem_ev = sum(ev * (sim_biden_margin > 0))) %>%
  ungroup() %>%
  summarise(mean(dem_ev >=270))

# scenarios
tipping_point %>%
  group_by(draw) %>%
  summarise(dem_ev = sum(ev * (sim_biden_margin > 0)),
            dem_nat_pop_margin = unique(dem_nat_pop_margin)) %>%
  mutate(scenario = 
           case_when(dem_ev >= 270 & dem_nat_pop_margin > 0 ~ 'D EC D vote',
                     dem_ev >= 270 & dem_nat_pop_margin < 0 ~ 'D EC R vote',
                     dem_ev <  270 & dem_nat_pop_margin > 0 ~ 'R EC D vote',
                     dem_ev <  270 & dem_nat_pop_margin < 0 ~ 'D EC R vote',
                     )) %>%
  group_by(scenario) %>%
  summarise(prop = n()) %>%
  mutate(prop = prop / sum(prop))

